import Core
import Foundation

/// `ToolExecutor` that returns verbatim verse text from local storage, so the
/// model grounds Bible work in the user's actual translation rather than its own
/// recollection.
///
/// A strict, read-only lookup: given a book, chapter, optional verse range, and
/// optional translation, it returns every requested verse with its number. The
/// tool resolves the book name (or 3-letter code) through `BibleBookCatalog`,
/// validates the translation against the bundled set, and — when `translation`
/// is omitted — falls back to the user's currently selected translation read from
/// the reading-position store.
///
/// Like the other Bible tools it rejects bad input *softly*: a missing field or
/// out-of-range reference returns a `ToolResult` with `isError: true` and a
/// remediation message, so the LLM (Large Language Model) can correct its
/// arguments instead of tearing down the whole turn.
public struct ReadBibleTool: ToolExecutor {
    /// Dotted form namespaces the tool under its applet, matching `bible.annotate`
    /// and `bible.note`.
    public static let toolID = "bible.read"

    public static let appletID = "bible"

    public let toolID: String = ReadBibleTool.toolID

    private let textLoader: any BibleTextLoader
    /// `nil` when `bible.sqlite` failed to open — the tool then falls back to the
    /// default translation whenever `translation` is omitted.
    private let positionRepository: (any BibleReadingPositionRepository)?
    private let catalog: BibleBookCatalog

    public init(
        textLoader: any BibleTextLoader,
        positionRepository: (any BibleReadingPositionRepository)?,
        catalog: BibleBookCatalog = .standard
    ) {
        self.textLoader = textLoader
        self.positionRepository = positionRepository
        self.catalog = catalog
    }

    public static let descriptor: LLMTool = LLMTool(
        id: ReadBibleTool.toolID,
        name: "bible.read",
        description: """
        Look up the exact text of a Bible passage from the user's local \
        storage. Call this before summarizing, explaining, quoting, or \
        otherwise relying on a specific passage — even if you already know \
        it — so your answer matches the user's selected translation rather \
        than your memory.

        Pass the `book` (full name like "John" or "1 Corinthians", or its \
        3-letter code) and the 1-based `chapter`. For the verse argument:
        - omit both `startVerse` and `endVerse` to get the whole chapter;
        - pass only `startVerse` to get that single verse;
        - pass both for an inclusive range (`endVerse` ≥ `startVerse`).

        Omit `translation` to use the user's currently selected translation \
        (the usual case). Only pass it when the user explicitly names a \
        different one. The tool returns each verse prefixed with its number; \
        quote from that, not from memory.
        """,
        category: .query,
        parameters: [
            LLMToolParameter(
                name: "book",
                type: .string,
                description: "Book to read: a full name like 'John', '1 Corinthians', 'Psalms', or its 3-letter code ('JHN', '1CO', 'PSA').",
                isRequired: true
            ),
            LLMToolParameter(
                name: "chapter",
                type: .integer,
                description: "1-based chapter number.",
                isRequired: true
            ),
            LLMToolParameter(
                name: "startVerse",
                type: .integer,
                description: "1-based first verse. Omit (along with endVerse) to read the whole chapter; pass alone to read a single verse.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "endVerse",
                type: .integer,
                description: "1-based last verse, ≥ startVerse. Requires startVerse. Omit to read a single verse or the whole chapter.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "translation",
                type: .string,
                description: "Optional translation code: 'KJV', 'WEB', 'ASV', or 'BSB'. Omit to use the user's currently selected translation, which is almost always what they want.",
                isRequired: false,
                enumValues: BibleTranslation.allCases.map(\.rawValue)
            ),
        ],
        appletId: ReadBibleTool.appletID,
        displayName: "Read scripture",
        summary: "Looks up exact verse text from local storage."
    )

    /// Build a `ToolRegistration` ready to hand to `ToolRegistry.register(_:)`.
    /// The composition root calls this in each app's bootstrap.
    public static func registration(
        textLoader: any BibleTextLoader,
        positionRepository: (any BibleReadingPositionRepository)?,
        catalog: BibleBookCatalog = .standard
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(ReadBibleTool(
                textLoader: textLoader,
                positionRepository: positionRepository,
                catalog: catalog
            )),
            isEnabled: true
        )
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        // 1. Book — required, resolved by name or code.
        guard let bookRaw = Self.optionalString(input, key: "book"), !bookRaw.isEmpty else {
            return Self.errorResult("book is required. Pass a full book name like 'John' or '1 Corinthians'.")
        }
        guard let summary = catalog.resolve(bookName: bookRaw) else {
            return Self.errorResult("Unknown or ambiguous book '\(bookRaw)'. Use a full book name like 'John' or '1 Corinthians', or a 3-letter code like 'JHN'.")
        }

        // 2. Chapter — required, within the book's bounds.
        guard let chapterNumber = Self.optionalInt(input, key: "chapter") else {
            return Self.errorResult("chapter is required. Pass a 1-based chapter number.")
        }
        guard chapterNumber >= 1, chapterNumber <= summary.chapterCount else {
            return Self.errorResult("Chapter \(chapterNumber) is out of range; \(summary.name) has \(summary.chapterCount) chapter\(summary.chapterCount == 1 ? "" : "s").")
        }

        // 3. Verse range (single-verse-friendly) and 4. translation — explicit
        // (validated strictly) or the user's current selection.
        let range: VerseRange
        let translation: BibleTranslation
        do {
            range = try Self.resolveRange(input)
            translation = try await resolveTranslation(input)
        } catch let error as ValidationError {
            return Self.errorResult(error.message)
        }

        // 5. Load and slice.
        let book: BibleBook
        do {
            book = try textLoader.loadBook(id: summary.id, translation: translation)
        } catch {
            return Self.errorResult("Couldn't load \(summary.name) (\(translation.rawValue)).")
        }
        guard let chapter = book.chapter(chapterNumber) else {
            return Self.errorResult("Chapter \(chapterNumber) is not available in \(summary.name) (\(translation.rawValue)).")
        }

        let allVerses = chapter.coalescedVerses()
        let maxVerse = allVerses.last?.number ?? 0
        let selected: [BibleVerse]
        let citedNumbers: [Int]
        switch range {
        case .wholeChapter:
            selected = allVerses
            citedNumbers = []
        case .single(let number), .span(let number, _):
            guard number <= maxVerse else {
                return Self.errorResult("Verse \(number) not found in \(summary.name) \(chapterNumber); the chapter has \(maxVerse) verse\(maxVerse == 1 ? "" : "s").")
            }
            // Lenient upper bound: clamp an over-long range to the last verse
            // rather than erroring, so "16-9999" returns 16…end.
            let upper = range.upperBound.map { min($0, maxVerse) } ?? number
            selected = allVerses.filter { $0.number >= number && $0.number <= upper }
            citedNumbers = selected.map(\.number)
        }

        let citation = BibleCitationFormatter.cite(
            bookName: summary.name, chapterNumber: chapterNumber, verses: citedNumbers
        )
        let content = "\(citation) (\(translation.rawValue))\n\n" + BibleVerseTextFormatter.numbered(selected)
        return ToolResult(toolID: ReadBibleTool.toolID, content: content, isError: false)
    }

    // MARK: - Verse range

    /// The resolved verse selection. `span`'s `end` is the requested upper bound
    /// before clamping to the chapter length.
    private enum VerseRange {
        case wholeChapter
        case single(Int)
        case span(Int, Int)

        /// The requested inclusive upper verse, or `nil` for a single verse /
        /// whole chapter (where there is no separate end to clamp).
        var upperBound: Int? {
            switch self {
            case .wholeChapter, .single: nil
            case .span(_, let end): end
            }
        }
    }

    /// Apply the single-verse-friendly rules to the `startVerse`/`endVerse`
    /// arguments. Both absent → whole chapter; start only → single verse; both →
    /// span; end without start → error; any non-positive bound → error.
    private static func resolveRange(_ input: [String: JSONValue]) throws -> VerseRange {
        let start = optionalInt(input, key: "startVerse")
        let end = optionalInt(input, key: "endVerse")
        switch (start, end) {
        case (nil, nil):
            return .wholeChapter
        case (nil, .some):
            throw ValidationError("endVerse was provided without startVerse. Pass startVerse too, or omit both to read the whole chapter.")
        case (.some(let s), nil):
            guard s >= 1 else { throw ValidationError("startVerse must be ≥ 1.") }
            return .single(s)
        case (.some(let s), .some(let e)):
            guard s >= 1 else { throw ValidationError("startVerse must be ≥ 1.") }
            guard e >= s else { throw ValidationError("endVerse (\(e)) must be ≥ startVerse (\(s)).") }
            return .span(s, e)
        }
    }

    // MARK: - Translation

    /// Resolve the translation: an explicit, strictly-validated `translation`
    /// argument, or — when omitted/blank — the user's currently selected
    /// translation (falling back to the default when no position is stored or the
    /// store is unavailable).
    private func resolveTranslation(_ input: [String: JSONValue]) async throws -> BibleTranslation {
        if let raw = Self.optionalString(input, key: "translation"),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            // Strict: `init(rawValue:)`, never `.named(_:)`, so an unknown code is
            // an error the model can correct rather than a silent fallback.
            guard let translation = BibleTranslation(rawValue: code) else {
                let valid = BibleTranslation.allCases.map(\.rawValue).joined(separator: ", ")
                throw ValidationError("Unknown translation '\(raw)'. Available: \(valid).")
            }
            return translation
        }
        var storedCode: String?
        if let positionRepository {
            storedCode = (try? await positionRepository.load())?.translationId
        }
        return storedCode.flatMap(BibleTranslation.init(rawValue:)) ?? .defaultTranslation
    }

    // MARK: - JSON parsing

    private static func optionalString(_ input: [String: JSONValue], key: String) -> String? {
        guard case .string(let value) = input[key] else { return nil }
        return value
    }

    private static func optionalInt(_ input: [String: JSONValue], key: String) -> Int? {
        guard let raw = input[key] else { return nil }
        if case .int(let value) = raw { return value }
        if case .double(let value) = raw {
            // Some providers serialize integers as doubles; round-trip safely.
            let rounded = Int(value)
            return Double(rounded) == value ? rounded : nil
        }
        return nil
    }

    private static func errorResult(_ message: String) -> ToolResult {
        ToolResult(toolID: ReadBibleTool.toolID, content: message, isError: true)
    }

    /// A soft input failure, caught in `execute` and returned as an `isError`
    /// `ToolResult` so the model can correct its arguments.
    private struct ValidationError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
