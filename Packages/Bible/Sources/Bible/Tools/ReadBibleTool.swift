import Core
import Foundation

/// `ToolExecutor` that returns verbatim verse text from local storage, so the
/// model grounds Bible work in the user's actual translation rather than its own
/// recollection.
///
/// A strict, read-only lookup over a `references` array: each reference names a
/// book, chapter, and optional verse range, and the tool returns every requested
/// verse with its number. References may span different books and chapters, so a
/// single call can gather a cross-reference set, a topical list, or a reading
/// plan's verses. The tool resolves each book name (or 3-letter code) through
/// `BibleBookCatalog`, validates the single top-level `translation` against the
/// bundled set, and — when `translation` is omitted — falls back to the user's
/// currently selected translation read from the reading-position store.
///
/// Like the other Bible tools it rejects bad input *softly*. Crucially, failures
/// are **per reference**: a malformed or out-of-range reference does not sink the
/// rest of the call. When some references succeed and some fail, the tool returns
/// the good passages plus a correctable note for each failure (`isError: false`);
/// only when *every* reference fails is the whole call an error.
///
/// This is the *read* execution core fronted by `LookupBibleTool` (the public
/// `bible.lookup` tool with an `action` discriminator) — it owns no descriptor
/// or registration of its own; the lookup tool dispatches `action:'read'` here
/// with the `references`/`translation` input it advertises.
public struct ReadBibleTool: ToolExecutor {
    /// Dotted form namespaces the result's tool id under its applet. The
    /// advertised tool is now `bible.lookup`; `LookupBibleTool` re-stamps this
    /// core's result with its own id.
    public static let toolID = "bible.read"

    public static let appletID = "bible"

    public let toolID: String = ReadBibleTool.toolID

    /// Upper bound on references per call. Keeps a single tool result digestible
    /// and bounds the worst case a model can request in one turn.
    static let maxReferences = 25

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

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        // 1. references — required, non-empty, within the per-call cap.
        guard case .array(let rawReferences)? = input["references"], !rawReferences.isEmpty else {
            return Self.errorResult("references is required. Pass an array of at least one passage, each with a book and chapter — e.g. [{\"book\":\"John\",\"chapter\":3,\"startVerse\":16}].")
        }
        guard rawReferences.count <= Self.maxReferences else {
            return Self.errorResult("Too many references (\(rawReferences.count)); a read reads at most \(Self.maxReferences) passages per call. Split the request into multiple calls.")
        }

        // 2. translation — resolved once; applies to every reference. An unknown
        // explicit code is a correctable error for the whole call.
        let translation: BibleTranslation
        do {
            translation = try await BibleToolTranslationResolver.resolve(
                explicitCode: Self.optionalString(input, key: "translation"),
                positionRepository: positionRepository
            )
        } catch let error as BibleToolValidationError {
            return Self.errorResult(error.message)
        }

        // 3. Resolve each reference independently; partition successes/failures
        // so one bad reference doesn't sink the rest.
        var passages: [String] = []
        var failures: [String] = []
        for raw in rawReferences {
            guard case .object(let reference) = raw else {
                failures.append("Each reference must be an object with a book and chapter.")
                continue
            }
            switch readOne(reference: reference, translation: translation) {
            case .passage(let content): passages.append(content)
            case .failure(let message): failures.append(message)
            }
        }

        return Self.combine(passages: passages, failures: failures, total: rawReferences.count)
    }

    // MARK: - Single reference

    /// The outcome of reading one reference: a formatted passage, or a
    /// remediation message the caller surfaces as a correctable note.
    private enum ReadOutcome {
        case passage(String)
        case failure(String)
    }

    /// Read one reference's verses, returning either the formatted passage or a
    /// remediation message. `translation` is already resolved (top-level), so this
    /// holds the pure book → chapter → range → load → slice → format pipeline.
    private func readOne(
        reference: [String: JSONValue], translation: BibleTranslation
    ) -> ReadOutcome {
        // Book — required, resolved by name or code.
        guard let bookRaw = Self.optionalString(reference, key: "book"), !bookRaw.isEmpty else {
            return .failure("book is required. Pass a full book name like 'John' or '1 Corinthians'.")
        }
        guard let summary = catalog.resolve(bookName: bookRaw) else {
            return .failure("Unknown or ambiguous book '\(bookRaw)'. Use a full book name like 'John' or '1 Corinthians', or a 3-letter code like 'JHN'.")
        }

        // Chapter — required, within the book's bounds.
        guard let chapterNumber = Self.optionalInt(reference, key: "chapter") else {
            return .failure("chapter is required. Pass a 1-based chapter number.")
        }
        guard chapterNumber >= 1, chapterNumber <= summary.chapterCount else {
            return .failure("Chapter \(chapterNumber) is out of range; \(summary.name) has \(summary.chapterCount) chapter\(summary.chapterCount == 1 ? "" : "s").")
        }

        // Verse range (single-verse-friendly).
        let range: VerseRange
        do {
            range = try Self.resolveRange(reference)
        } catch let error as BibleToolValidationError {
            return .failure(error.message)
        } catch {
            return .failure("Invalid verse range.")
        }

        // Load and slice.
        let loaded: BibleChapter?
        do {
            loaded = try textLoader.loadChapter(
                bookId: summary.id, chapterNumber: chapterNumber, translation: translation
            )
        } catch {
            return .failure("Couldn't load \(summary.name) (\(translation.rawValue)).")
        }
        guard let chapter = loaded else {
            return .failure("Chapter \(chapterNumber) is not available in \(summary.name) (\(translation.rawValue)).")
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
                return .failure("Verse \(number) not found in \(summary.name) \(chapterNumber); the chapter has \(maxVerse) verse\(maxVerse == 1 ? "" : "s").")
            }
            // Lenient upper bound: clamp an over-long range to the last verse
            // rather than erroring, so "16-9999" returns 16…end.
            let upper = range.upperBound.map { min($0, maxVerse) } ?? number
            selected = allVerses.filter { $0.number >= number && $0.number <= upper }
            // `number <= maxVerse` is a bound, not a membership check: bundled
            // text has real verse-number gaps (textual variants some
            // translations omit, e.g. Acts 8:37 in WEB). A request that lands
            // entirely in such a gap selects nothing — error rather than return
            // a confident citation header over an empty body, which is exactly
            // the silent-grounding failure this tool exists to prevent. A range
            // that drops only *interior* omitted verses still returns its
            // present verses (the citation reflects which ones).
            guard !selected.isEmpty else {
                let requested = range.upperBound == nil
                    ? "\(summary.name) \(chapterNumber):\(number)"
                    : "\(summary.name) \(chapterNumber):\(number)-\(upper)"
                return .failure("\(requested) (\(translation.rawValue)) has no verse text in this translation — those verse numbers are omitted here, as a textual variant some translations don't include. Try an adjacent verse.")
            }
            citedNumbers = selected.map(\.number)
        }

        let citation = BibleCitationFormatter.cite(
            bookName: summary.name, chapterNumber: chapterNumber, verses: citedNumbers
        )
        let content = "\(citation) (\(translation.rawValue))\n\n" + BibleVerseTextFormatter.numbered(selected)
        return .passage(content)
    }

    // MARK: - Assembly

    /// Combine per-reference results into one `ToolResult`. All-fail is the only
    /// error case; a partial mix returns the good passages plus correctable notes.
    private static func combine(passages: [String], failures: [String], total: Int) -> ToolResult {
        if passages.isEmpty {
            // Every reference failed. A single failure stays byte-identical to the
            // old single-passage error; multiple failures list each message.
            let content = failures.count == 1
                ? failures[0]
                : "None of the \(total) references could be read:\n" + bullets(failures)
            return Self.errorResult(content)
        }
        if failures.isEmpty {
            return ToolResult(toolID: toolID, content: passages.joined(separator: "\n\n"), isError: false)
        }
        // Partial success: passages, then a correctable note per failed reference.
        let note = "⚠︎ \(failures.count) of \(total) references couldn't be read:\n" + bullets(failures)
        let content = passages.joined(separator: "\n\n") + "\n\n" + note
        return ToolResult(toolID: toolID, content: content, isError: false)
    }

    private static func bullets(_ messages: [String]) -> String {
        messages.map { "• \($0)" }.joined(separator: "\n")
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

    /// Apply the single-verse-friendly rules to a reference's `startVerse`/
    /// `endVerse` arguments. Both absent → whole chapter; start only → single
    /// verse; both → span; end without start → error; any non-positive bound →
    /// error.
    private static func resolveRange(_ reference: [String: JSONValue]) throws -> VerseRange {
        let start = optionalInt(reference, key: "startVerse")
        let end = optionalInt(reference, key: "endVerse")
        switch (start, end) {
        case (nil, nil):
            return .wholeChapter
        case (nil, .some):
            throw BibleToolValidationError("endVerse was provided without startVerse. Pass startVerse too, or omit both to read the whole chapter.")
        case (.some(let s), nil):
            guard s >= 1 else { throw BibleToolValidationError("startVerse must be ≥ 1.") }
            return .single(s)
        case (.some(let s), .some(let e)):
            guard s >= 1 else { throw BibleToolValidationError("startVerse must be ≥ 1.") }
            guard e >= s else { throw BibleToolValidationError("endVerse (\(e)) must be ≥ startVerse (\(s)).") }
            return .span(s, e)
        }
    }

    // MARK: - JSON parsing

    private static func optionalString(_ input: [String: JSONValue], key: String) -> String? {
        BibleToolJSON.optionalString(input, key: key)
    }

    private static func optionalInt(_ input: [String: JSONValue], key: String) -> Int? {
        BibleToolJSON.optionalInt(input, key: key)
    }

    private static func errorResult(_ message: String) -> ToolResult {
        ToolResult(toolID: ReadBibleTool.toolID, content: message, isError: true)
    }
}
