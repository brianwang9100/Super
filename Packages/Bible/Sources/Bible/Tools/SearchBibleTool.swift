import Core
import Foundation

/// `ToolExecutor` that finds verses by *content* — the retrieval-by-content
/// sibling of `ReadBibleTool`'s retrieval-by-reference.
///
/// Given free-text terms, an optional translation, and an optional book scope, it
/// runs a ranked full-text search over the bundled `bible-text.sqlite` FTS index
/// and returns the matching verses with correct citations, so the model answers
/// thematic questions ("verses about anxiety") from real retrieved scripture
/// rather than recall.
///
/// Like the other Bible tools it rejects bad input *softly*: malformed arguments
/// return a `ToolResult` with `isError: true` and a remediation message. A search
/// that simply finds nothing is **not** an error — an empty result set is a valid
/// answer the model can act on.
///
/// This is the *search* execution core fronted by `LookupBibleTool` (the public
/// `bible.lookup` tool with an `action` discriminator) — it owns no descriptor
/// or registration of its own; the lookup tool dispatches `action:'search'`
/// here with the `query`/`match`/`book`/`limit`/`translation` input it advertises.
public struct SearchBibleTool: ToolExecutor {
    /// Dotted form namespaces the result's tool id under its applet. The
    /// advertised tool is now `bible.lookup`; `LookupBibleTool` re-stamps this
    /// core's result with its own id.
    public static let toolID = "bible.search"

    public static let appletID = "bible"

    public let toolID: String = SearchBibleTool.toolID

    /// Default and maximum result counts. The default keeps a single tool result
    /// digestible; the cap bounds the worst case a model can request.
    static let defaultLimit = 20
    static let maxLimit = 50

    private let searcher: any BibleTextSearching
    /// `nil` when `bible.sqlite` failed to open — the tool then falls back to the
    /// default translation whenever `translation` is omitted.
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
        // 1. Query — required, non-blank.
        guard let queryRaw = Self.optionalString(input, key: "query"),
              !queryRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.errorResult("query is required. Pass the words or phrase to search for.")
        }
        let query = queryRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Translation — explicit (validated strictly) or current selection.
        let translation: BibleTranslation
        do {
            translation = try await BibleToolTranslationResolver.resolve(
                explicitCode: Self.optionalString(input, key: "translation"),
                positionRepository: positionRepository
            )
        } catch let error as BibleToolValidationError {
            return Self.errorResult(error.message)
        }

        // 3. Book scope — optional; present-but-unresolvable is an error.
        var bookScope: BibleBookSummary?
        if let bookRaw = Self.optionalString(input, key: "book"),
           !bookRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let summary = catalog.resolve(bookName: bookRaw) else {
                return Self.errorResult("Unknown or ambiguous book '\(bookRaw)'. Use a full book name like 'Romans' or '1 Corinthians', or a 3-letter code like 'ROM' — or omit it to search the whole Bible.")
            }
            bookScope = summary
        }

        // 4. Limit — clamp to a sane window.
        let limit = min(max(Self.optionalInt(input, key: "limit") ?? Self.defaultLimit, 1), Self.maxLimit)

        // 5. Match mode — forgiving `any` by default; an unknown value is not an
        // error, it just falls back to the default rather than failing the call.
        let mode = BibleSearchMatchMode(rawValue: Self.optionalString(input, key: "match") ?? "") ?? .any

        // 6. Search.
        let matches: [BibleVerseMatch]
        do {
            matches = try await searcher.search(
                query: query, translation: translation, bookId: bookScope?.id, mode: mode, limit: limit
            )
        } catch {
            return Self.errorResult("Couldn't search scripture right now.")
        }

        // 7. Zero hits is a valid answer, not a malformed call.
        guard !matches.isEmpty else {
            let scope = bookScope.map { " in \($0.name)" } ?? ""
            return ToolResult(
                toolID: SearchBibleTool.toolID,
                content: "No verses\(scope) (\(translation.rawValue)) matched \"\(query)\". Try different or broader terms.",
                isError: false
            )
        }

        // 8. Ranked, cited results.
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
