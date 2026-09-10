import Core
import Foundation

/// Read execution behind LookupBibleTool, with one translation for the entire call.
/// References fail independently: partial success returns passages plus correction
/// notes with isError false; only all-failed references make the result an error.
public struct ReadBibleTool: ToolExecutor {
    public static let toolID = "bible.read"

    public static let appletID = "bible"

    public let toolID: String = ReadBibleTool.toolID

    // Bound retrieval cost and model-context size per call.
    static let maxReferences = 25

    private let textLoader: any BibleTextLoader
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
        guard case .array(let rawReferences)? = input["references"], !rawReferences.isEmpty else {
            return Self.errorResult("references is required. Pass an array of at least one passage, each with a book and chapter — e.g. [{\"book\":\"John\",\"chapter\":3,\"startVerse\":16}].")
        }
        guard rawReferences.count <= Self.maxReferences else {
            return Self.errorResult("Too many references (\(rawReferences.count)); a read reads at most \(Self.maxReferences) passages per call. Split the request into multiple calls.")
        }

        // Translation is shared; an invalid explicit code rejects the whole call.
        let translation: BibleTranslation
        do {
            translation = try await BibleToolTranslationResolver.resolve(
                explicitCode: Self.optionalString(input, key: "translation"),
                positionRepository: positionRepository
            )
        } catch let error as BibleToolValidationError {
            return Self.errorResult(error.message)
        }

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

    private enum ReadOutcome {
        case passage(String)
        case failure(String)
    }

    private func readOne(
        reference: [String: JSONValue], translation: BibleTranslation
    ) -> ReadOutcome {
        guard let bookRaw = Self.optionalString(reference, key: "book"), !bookRaw.isEmpty else {
            return .failure("book is required. Pass a full book name like 'John' or '1 Corinthians'.")
        }
        guard let summary = catalog.resolve(bookName: bookRaw) else {
            return .failure("Unknown or ambiguous book '\(bookRaw)'. Use a full book name like 'John' or '1 Corinthians', or a 3-letter code like 'JHN'.")
        }

        guard let chapterNumber = Self.optionalInt(reference, key: "chapter") else {
            return .failure("chapter is required. Pass a 1-based chapter number.")
        }
        guard chapterNumber >= 1, chapterNumber <= summary.chapterCount else {
            return .failure("Chapter \(chapterNumber) is out of range; \(summary.name) has \(summary.chapterCount) chapter\(summary.chapterCount == 1 ? "" : "s").")
        }

        let range: VerseRange
        do {
            range = try Self.resolveRange(reference)
        } catch let error as BibleToolValidationError {
            return .failure(error.message)
        } catch {
            return .failure("Invalid verse range.")
        }

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
            // Clamp oversized upper bounds so a request like 16-9999 reads through the end.
            let upper = range.upperBound.map { min($0, maxVerse) } ?? number
            selected = allVerses.filter { $0.number >= number && $0.number <= upper }
            // Bounds do not imply membership: translations omit some verse numbers. Reject an
            // entirely empty selection; otherwise return present verses and cite only those.
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

    private static func combine(passages: [String], failures: [String], total: Int) -> ToolResult {
        if passages.isEmpty {
            let content = failures.count == 1
                ? failures[0]
                : "None of the \(total) references could be read:\n" + bullets(failures)
            return Self.errorResult(content)
        }
        if failures.isEmpty {
            return ToolResult(toolID: toolID, content: passages.joined(separator: "\n\n"), isError: false)
        }
        let note = "⚠︎ \(failures.count) of \(total) references couldn't be read:\n" + bullets(failures)
        let content = passages.joined(separator: "\n\n") + "\n\n" + note
        return ToolResult(toolID: toolID, content: content, isError: false)
    }

    private static func bullets(_ messages: [String]) -> String {
        messages.map { "• \($0)" }.joined(separator: "\n")
    }

    // MARK: - Verse range

    // span retains the requested upper bound until chapter-length clamping.
    private enum VerseRange {
        case wholeChapter
        case single(Int)
        case span(Int, Int)

        var upperBound: Int? {
            switch self {
            case .wholeChapter, .single: nil
            case .span(_, let end): end
            }
        }
    }

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
