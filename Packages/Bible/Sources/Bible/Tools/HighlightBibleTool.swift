import Core
import Foundation

/// Highlights are translation-independent. Clear needs no confirmation because
/// soft-deleted highlights can be restored. Invalid arguments return correctable
/// error results without terminating the model's turn.
public struct HighlightBibleTool: ToolExecutor {
    public static let toolID = "bible.highlight"

    public static let appletID = "bible"

    public let toolID: String = HighlightBibleTool.toolID

    private let repository: any BibleHighlightRepository
    private let clock: any Clock
    private let catalog: BibleBookCatalog

    public init(
        repository: any BibleHighlightRepository,
        clock: any Clock = SystemClock(),
        catalog: BibleBookCatalog = .standard
    ) {
        self.repository = repository
        self.clock = clock
        self.catalog = catalog
    }

    public static let descriptor: LLMTool = LLMTool(
        id: HighlightBibleTool.toolID,
        name: "bible.highlight",
        description: """
        Read, search, set, or clear the reader's verse highlights. A highlight \
        is a coloured wash the reader paints on a verse; the five colours are \
        yellow, green, blue, pink, and lavender. Highlights are saved per verse \
        and shared across translations.

        The `action` decides which other fields are required:
        - `"read"`: `book` + `chapter` (+ optional `verseStart`/`verseEnd`). \
        Returns each highlighted verse's colour, or that the passage has none.
        - `"search"`: `color` (required) + optional `book`. Returns every verse \
        currently highlighted with that colour — the whole bible unless `book` \
        narrows it.
        - `"set"`: `book` + `chapter` + `verseStart` (+ optional `verseEnd`) + \
        `color`. Highlights those verses; recolouring an already-highlighted \
        verse is fine.
        - `"clear"`: `book` + `chapter` + `verseStart` (+ optional `verseEnd`). \
        Removes the highlights on those verses.

        `book` accepts a full name like "John" or "1 Corinthians", or its \
        3-letter code ("JHN"). Omit `verseEnd` to act on a single verse. \
        `set` and `clear` require a verse range — the whole chapter is not a \
        valid target for them; name the verses.
        """,
        category: .mutation,
        parameters: [
            LLMToolParameter(
                name: "action",
                type: .string,
                description: "What to do: 'read' verses' colours, 'search' verses by colour, 'set' a highlight, or 'clear' highlights.",
                isRequired: true,
                enumValues: ["read", "search", "set", "clear"]
            ),
            LLMToolParameter(
                name: "book",
                type: .string,
                description: "Book: a full name like 'John' or '1 Corinthians', or its 3-letter code ('JHN'). Required for read/set/clear; optional for search (omit to search the whole bible).",
                isRequired: false
            ),
            LLMToolParameter(
                name: "chapter",
                type: .integer,
                description: "1-based chapter number. Required for read/set/clear.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "verseStart",
                type: .integer,
                description: "1-based first verse. Required for set/clear; for read, omit (with verseEnd) to read the whole chapter.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "verseEnd",
                type: .integer,
                description: "1-based last verse, ≥ verseStart. Omit to act on a single verse.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "color",
                type: .string,
                description: "Highlight colour. Required for 'set' and 'search'.",
                isRequired: false,
                enumValues: BibleHighlightColor.allCases.map(\.rawValue)
            ),
        ],
        appletId: HighlightBibleTool.appletID,
        displayName: "Bible highlights",
        summary: "Reads, searches, sets, or clears verse highlight colours."
    )

    public static func registration(
        repository: any BibleHighlightRepository,
        clock: any Clock = SystemClock(),
        catalog: BibleBookCatalog = .standard
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(HighlightBibleTool(
                repository: repository,
                clock: clock,
                catalog: catalog
            )),
            isEnabled: true
        )
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        let action: Action
        do {
            action = try validate(input: input)
        } catch let validation as ValidationError {
            return Self.errorResult(validation.message)
        }

        do {
            switch action {
            case .read(let book, let chapter, let range):
                return try await performRead(book: book, chapter: chapter, range: range)
            case .search(let color, let book):
                return try await performSearch(color: color, book: book)
            case .set(let book, let chapter, let range, let color):
                return try await performSet(book: book, chapter: chapter, range: range, color: color)
            case .clear(let book, let chapter, let range):
                return try await performClear(book: book, chapter: chapter, range: range)
            }
        } catch {
            return Self.errorResult("Failed to \(action.verb) highlights: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    private func performRead(
        book: BibleBookSummary, chapter: Int, range: ClosedRange<Int>?
    ) async throws -> ToolResult {
        let rows = try await repository.activeHighlights(bookId: book.id, chapterNumber: chapter)
        let relevant = range.map { range in rows.filter { range.contains($0.verseNumber) } } ?? rows

        let scope = BibleCitationFormatter.cite(
            bookName: book.name, chapterNumber: chapter, verses: range.map { Array($0) } ?? []
        )

        var versesByColor: [BibleHighlightColor: [Int]] = [:]
        for row in relevant {
            guard let color = row.color else { continue }
            versesByColor[color, default: []].append(row.verseNumber)
        }
        guard !versesByColor.isEmpty else {
            return Self.successResult("No highlights in \(scope).")
        }

        let clauses = BibleHighlightColor.allCases.compactMap { color -> String? in
            guard let verses = versesByColor[color], !verses.isEmpty else { return nil }
            return "\(color.displayName.lowercased()) \(BibleCitationFormatter.verseClause(verses))"
        }
        return Self.successResult("Highlights in \(scope) — " + clauses.joined(separator: "; ") + ".")
    }

    private func performSearch(
        color: BibleHighlightColor, book: BibleBookSummary?
    ) async throws -> ToolResult {
        let rows = try await repository.activeHighlights(color: color, bookId: book?.id)
        guard !rows.isEmpty else {
            let scope = book.map { " in \($0.name)" } ?? ""
            return Self.successResult("No verses highlighted \(color.displayName.lowercased())\(scope).")
        }

        var versesByBookChapter: [String: [Int: [Int]]] = [:]
        for row in rows {
            versesByBookChapter[row.bookId, default: [:]][row.chapterNumber, default: []].append(row.verseNumber)
        }
        var citations: [String] = []
        for summary in catalog.books {
            guard let chapters = versesByBookChapter[summary.id] else { continue }
            for chapter in chapters.keys.sorted() {
                citations.append(BibleCitationFormatter.cite(
                    bookName: summary.name, chapterNumber: chapter, verses: chapters[chapter] ?? []
                ))
            }
        }
        let scope = book.map { " in \($0.name)" } ?? ""
        return Self.successResult(
            "Highlighted \(color.displayName.lowercased())\(scope): " + citations.joined(separator: "; ") + "."
        )
    }

    private func performSet(
        book: BibleBookSummary, chapter: Int, range: ClosedRange<Int>, color: BibleHighlightColor
    ) async throws -> ToolResult {
        let now = clock.now()
        for verse in range {
            try await repository.setHighlight(
                bookId: book.id, chapterNumber: chapter, verseNumber: verse, color: color, at: now
            )
        }
        let citation = BibleCitationFormatter.cite(
            bookName: book.name, chapterNumber: chapter, verses: Array(range)
        )
        return Self.successResult("Highlighted \(color.displayName.lowercased()): \(citation).")
    }

    private func performClear(
        book: BibleBookSummary, chapter: Int, range: ClosedRange<Int>
    ) async throws -> ToolResult {
        let now = clock.now()
        for verse in range {
            try await repository.clearHighlight(
                bookId: book.id, chapterNumber: chapter, verseNumber: verse, at: now
            )
        }
        let citation = BibleCitationFormatter.cite(
            bookName: book.name, chapterNumber: chapter, verses: Array(range)
        )
        return Self.successResult("Cleared highlights: \(citation).")
    }

    // MARK: - Validation

    private enum Action {
        case read(book: BibleBookSummary, chapter: Int, range: ClosedRange<Int>?)
        case search(color: BibleHighlightColor, book: BibleBookSummary?)
        case set(book: BibleBookSummary, chapter: Int, range: ClosedRange<Int>, color: BibleHighlightColor)
        case clear(book: BibleBookSummary, chapter: Int, range: ClosedRange<Int>)

        var verb: String {
            switch self {
            case .read: "read"
            case .search: "search"
            case .set: "set"
            case .clear: "clear"
            }
        }
    }

    private struct ValidationError: Error {
        let message: String
    }

    private func validate(input: [String: JSONValue]) throws -> Action {
        let actionRaw = try Self.requireString(input, key: "action")
        switch actionRaw {
        case "read":
            let (book, chapter) = try resolveBookAndChapter(input)
            return .read(book: book, chapter: chapter, range: try Self.resolveRange(input))
        case "search":
            let color = try Self.requireColor(input)
            return .search(color: color, book: try resolveOptionalBook(input))
        case "set":
            let (book, chapter) = try resolveBookAndChapter(input)
            let range = try requireRange(input, verb: "set")
            return .set(book: book, chapter: chapter, range: range, color: try Self.requireColor(input))
        case "clear":
            let (book, chapter) = try resolveBookAndChapter(input)
            return .clear(book: book, chapter: chapter, range: try requireRange(input, verb: "clear"))
        default:
            throw ValidationError(message: "Unknown action '\(actionRaw)'. Use 'read', 'search', 'set', or 'clear'.")
        }
    }

    private func resolveBookAndChapter(_ input: [String: JSONValue]) throws -> (BibleBookSummary, Int) {
        guard let bookRaw = BibleToolJSON.optionalString(input, key: "book"), !bookRaw.isEmpty else {
            throw ValidationError(message: "book is required. Pass a full book name like 'John' or '1 Corinthians', or a 3-letter code like 'JHN'.")
        }
        guard let summary = catalog.resolve(bookName: bookRaw) else {
            throw ValidationError(message: "Unknown or ambiguous book '\(bookRaw)'. Use a full book name like 'John' or '1 Corinthians', or a 3-letter code like 'JHN'.")
        }
        guard let chapter = BibleToolJSON.optionalInt(input, key: "chapter") else {
            throw ValidationError(message: "chapter is required. Pass a 1-based chapter number.")
        }
        guard chapter >= 1, chapter <= summary.chapterCount else {
            throw ValidationError(message: "Chapter \(chapter) is out of range; \(summary.name) has \(summary.chapterCount) chapter\(summary.chapterCount == 1 ? "" : "s").")
        }
        return (summary, chapter)
    }

    private func resolveOptionalBook(_ input: [String: JSONValue]) throws -> BibleBookSummary? {
        guard let bookRaw = BibleToolJSON.optionalString(input, key: "book"), !bookRaw.isEmpty else {
            return nil
        }
        guard let summary = catalog.resolve(bookName: bookRaw) else {
            throw ValidationError(message: "Unknown or ambiguous book '\(bookRaw)'. Use a full book name like 'John' or '1 Corinthians', or a 3-letter code like 'JHN'.")
        }
        return summary
    }

    /// Require a bounded range: each verse causes a write and no loader supplies the
    /// chapter's actual verse count. Missing ranges must not imply unbounded whole-chapter work.
    private func requireRange(_ input: [String: JSONValue], verb: String) throws -> ClosedRange<Int> {
        guard let range = try Self.resolveRange(input) else {
            throw ValidationError(message: "\(verb) requires a verse range: pass verseStart (and an optional verseEnd). The whole chapter is not a valid target for \(verb).")
        }
        guard range.count <= Self.maxVerseSpan else {
            throw ValidationError(message: "That range spans \(range.count) verses; \(verb) at most \(Self.maxVerseSpan) verses per call. Name the actual verses you mean — even the longest chapter has 176.")
        }
        return range
    }

    private static func requireColor(_ input: [String: JSONValue]) throws -> BibleHighlightColor {
        guard let raw = BibleToolJSON.optionalString(input, key: "color"), !raw.isEmpty else {
            throw ValidationError(message: "color is required. Use one of: \(colorList).")
        }
        guard let color = BibleHighlightColor(rawValue: raw.lowercased()) else {
            throw ValidationError(message: "Unknown color '\(raw)'. Use one of: \(colorList).")
        }
        return color
    }

    private static func resolveRange(_ input: [String: JSONValue]) throws -> ClosedRange<Int>? {
        let start = BibleToolJSON.optionalInt(input, key: "verseStart")
        let end = BibleToolJSON.optionalInt(input, key: "verseEnd")
        switch (start, end) {
        case (nil, nil):
            return nil
        case (nil, .some):
            throw ValidationError(message: "verseEnd was provided without verseStart. Pass verseStart too, or omit both.")
        case (.some(let s), nil):
            guard s >= 1 else { throw ValidationError(message: "verseStart must be ≥ 1.") }
            return s...s
        case (.some(let s), .some(let e)):
            guard s >= 1 else { throw ValidationError(message: "verseStart must be ≥ 1.") }
            guard e >= s else { throw ValidationError(message: "verseEnd (\(e)) must be ≥ verseStart (\(s)).") }
            return s...e
        }
    }

    // Bounds per-verse writes while admitting every real chapter (Psalm 119 has 176 verses).
    static let maxVerseSpan = 200

    private static let colorList = BibleHighlightColor.allCases.map(\.rawValue).joined(separator: ", ")

    private static func requireString(_ input: [String: JSONValue], key: String) throws -> String {
        guard case .string(let value) = input[key] else {
            throw ValidationError(message: "\(key) is required and must be a string.")
        }
        return value
    }

    private static func successResult(_ content: String) -> ToolResult {
        ToolResult(toolID: HighlightBibleTool.toolID, content: content, isError: false)
    }

    private static func errorResult(_ message: String) -> ToolResult {
        ToolResult(toolID: HighlightBibleTool.toolID, content: message, isError: true)
    }
}
