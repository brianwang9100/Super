import Core
import Foundation

/// Search execution behind LookupBibleTool. Empty matches are a valid answer;
/// malformed arguments return correctable error results.
public struct SearchBibleTool: ToolExecutor {
    public static let toolID = "bible.search"

    public static let appletID = "bible"

    public let toolID: String = SearchBibleTool.toolID

    // Bound result size and model-context use.
    static let defaultLimit = 20
    static let maxLimit = 50

    private let searcher: any BibleTextSearching
    private let positionRepository: (any BibleReadingPositionRepository)?
    private let catalog: BibleBookCatalog

    public init(
        searcher: any BibleTextSearching,
        positionRepository: (any BibleReadingPositionRepository)?,
        catalog: BibleBookCatalog = .standard
    ) {
        self.searcher = searcher
        self.positionRepository = positionRepository
        self.catalog = catalog
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        guard let queryRaw = Self.optionalString(input, key: "query"),
              !queryRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.errorResult("query is required. Pass the words or phrase to search for.")
        }
        let query = queryRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        let translation: BibleTranslation
        do {
            translation = try await BibleToolTranslationResolver.resolve(
                explicitCode: Self.optionalString(input, key: "translation"),
                positionRepository: positionRepository
            )
        } catch let error as BibleToolValidationError {
            return Self.errorResult(error.message)
        }

        var bookScope: BibleBookSummary?
        if let bookRaw = Self.optionalString(input, key: "book"),
           !bookRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let summary = catalog.resolve(bookName: bookRaw) else {
                return Self.errorResult("Unknown or ambiguous book '\(bookRaw)'. Use a full book name like 'Romans' or '1 Corinthians', or a 3-letter code like 'ROM' — or omit it to search the whole Bible.")
            }
            bookScope = summary
        }

        let limit = min(max(Self.optionalInt(input, key: "limit") ?? Self.defaultLimit, 1), Self.maxLimit)

        // Unknown match modes fall back to any; they do not reject the call.
        let mode = BibleSearchMatchMode(rawValue: Self.optionalString(input, key: "match") ?? "") ?? .any

        let matches: [BibleVerseMatch]
        do {
            matches = try await searcher.search(
                query: query, translation: translation, bookId: bookScope?.id, mode: mode, limit: limit
            )
        } catch {
            return Self.errorResult("Couldn't search scripture right now.")
        }

        guard !matches.isEmpty else {
            let scope = bookScope.map { " in \($0.name)" } ?? ""
            return ToolResult(
                toolID: SearchBibleTool.toolID,
                content: "No verses\(scope) (\(translation.rawValue)) matched \"\(query)\". Try different or broader terms.",
                isError: false
            )
        }

        let header = Self.header(count: matches.count, query: query, scope: bookScope, translation: translation)
        let lines = matches.map { match in
            let bookName = catalog.book(id: match.bookId)?.name ?? match.bookId
            let citation = BibleCitationFormatter.cite(
                bookName: bookName, chapterNumber: match.chapter, verses: [match.verse]
            )
            return "\(citation) — \(match.text)"
        }
        let content = header + "\n\n" + lines.joined(separator: "\n")
        return ToolResult(toolID: SearchBibleTool.toolID, content: content, isError: false)
    }

    // MARK: - Formatting

    private static func header(
        count: Int, query: String, scope: BibleBookSummary?, translation: BibleTranslation
    ) -> String {
        let plural = count == 1 ? "result" : "results"
        let scopeClause = scope.map { " in \($0.name)" } ?? ""
        return "\(count) \(plural) for \"\(query)\"\(scopeClause) (\(translation.rawValue)):"
    }

    // MARK: - JSON parsing

    private static func optionalString(_ input: [String: JSONValue], key: String) -> String? {
        BibleToolJSON.optionalString(input, key: key)
    }

    private static func optionalInt(_ input: [String: JSONValue], key: String) -> Int? {
        BibleToolJSON.optionalInt(input, key: key)
    }

    private static func errorResult(_ message: String) -> ToolResult {
        ToolResult(toolID: SearchBibleTool.toolID, content: message, isError: true)
    }
}
