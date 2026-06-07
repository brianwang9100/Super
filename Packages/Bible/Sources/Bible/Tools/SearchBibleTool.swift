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
public struct SearchBibleTool: ToolExecutor {
    /// Dotted form namespaces the tool under its applet, matching `bible.read`.
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

    public static let descriptor: LLMTool = LLMTool(
        id: SearchBibleTool.toolID,
        name: "bible.search",
        description: """
        Search the user's local scripture for verses matching a topic or phrase, \
        returning real, ranked verses with correct citations. Call this when the \
        user asks what the Bible says about a theme, or where something appears \
        ("verses about anxiety", "where does Paul talk about grace") — instead of \
        recalling verses from memory, which risks wrong text and invented \
        citations.

        Search is keyword-based with stemming: pass a few content words in \
        `query` (e.g. "love" also matches "loved"/"loving"). Optionally scope to \
        one `book`. Omit `translation` to search the user's currently selected \
        translation (the usual case). Results are ordered best-match first.

        Each result already includes the verse's full, exact text from the \
        user's translation — quote and cite directly from these results. Do NOT \
        call `bible.read` to re-fetch a verse you already got back from search; \
        that text is authoritative. Only call `bible.read` afterward when you \
        need the *surrounding* verses a result doesn't include (e.g. to read \
        the rest of the chapter for context).
        """,
        category: .query,
        parameters: [
            LLMToolParameter(
                name: "query",
                type: .string,
                description: "The words or phrase to search for, e.g. 'anxiety', 'love your enemies', 'shepherd'.",
                isRequired: true
            ),
            LLMToolParameter(
                name: "book",
                type: .string,
                description: "Optional book to limit the search to: a full name like 'Romans' or its 3-letter code ('ROM'). Omit to search the whole Bible.",
                isRequired: false
            ),
            LLMToolParameter(
                name: "limit",
                type: .integer,
                description: "Optional maximum number of results (default \(SearchBibleTool.defaultLimit), max \(SearchBibleTool.maxLimit)).",
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
        appletId: SearchBibleTool.appletID,
        displayName: "Search scripture",
        summary: "Finds verses by content from local storage."
    )

    /// Build a `ToolRegistration` ready to hand to `ToolRegistry.register(_:)`.
    /// The composition root calls this in each app's bootstrap.
    public static func registration(
        searcher: any BibleTextSearching,
        positionRepository: (any BibleReadingPositionRepository)?,
        catalog: BibleBookCatalog = .standard
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(SearchBibleTool(
                searcher: searcher,
                positionRepository: positionRepository,
                catalog: catalog
            )),
            isEnabled: true
        )
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

        // 5. Search.
        let matches: [BibleVerseMatch]
        do {
            matches = try await searcher.search(
                query: query, translation: translation, bookId: bookScope?.id, limit: limit
            )
        } catch {
            return Self.errorResult("Couldn't search scripture right now.")
        }

        // 6. Zero hits is a valid answer, not a malformed call.
        guard !matches.isEmpty else {
            let scope = bookScope.map { " in \($0.name)" } ?? ""
            return ToolResult(
                toolID: SearchBibleTool.toolID,
                content: "No verses\(scope) (\(translation.rawValue)) matched \"\(query)\". Try different or broader terms.",
                isError: false
            )
        }

        // 7. Ranked, cited results.
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
