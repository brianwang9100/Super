import Core
import Foundation

/// `ToolExecutor` that fronts both scripture-retrieval paths behind a single
/// `action` discriminator: `read` fetches exact passages by reference, `search`
/// finds verses by content. One tool instead of two keeps the schema the model
/// pays for on every turn smaller — the shared `translation` parameter and the
/// surrounding "ground every quote" guidance are declared once rather than
/// duplicated across `bible.read` and `bible.search`. On the compact tier this
/// is the difference between two full tool schemas and one.
///
/// Execution is pure delegation: the two paths keep their own executors
/// (`ReadBibleTool` / `SearchBibleTool`) — with all their per-reference
/// partial-success handling, translation resolution, and book scoping intact —
/// and this tool only routes by `action` and re-stamps the result with its own
/// `toolID`. Like its delegates it rejects bad input *softly*, so the model can
/// correct an action or a missing field rather than tearing down the turn.
public struct LookupBibleTool: ToolExecutor {
    /// Dotted form namespaces the tool under its applet, matching `bible.note`
    /// and `bible.annotate`. Replaces the former `bible.read` + `bible.search`.
    public static let toolID = "bible.lookup"

    public static let appletID = "bible"

    public let toolID: String = LookupBibleTool.toolID

    private let read: ReadBibleTool
    private let search: SearchBibleTool

    public init(
        textLoader: any BibleTextLoader,
        searcher: any BibleTextSearching,
        positionRepository: (any BibleReadingPositionRepository)?,
        catalog: BibleBookCatalog = .standard
    ) {
        self.read = ReadBibleTool(
            textLoader: textLoader, positionRepository: positionRepository, catalog: catalog
        )
        self.search = SearchBibleTool(
            searcher: searcher, positionRepository: positionRepository, catalog: catalog
        )
    }

    public static let descriptor: LLMTool = LLMTool(
        id: LookupBibleTool.toolID,
        name: "bible.lookup",
        description: """
        Look up scripture from the user's local storage. One tool, two actions \
        chosen by `action`:

        - `action:'read'` — fetch the exact text of passages you already know \
        the reference for. Pass `references`, an array of passage objects, each \
        `{book, chapter, optional startVerse/endVerse}` — omit both verses for \
        the whole chapter, pass `startVerse` alone for a single verse, or both \
        for an inclusive range. References may span different books and \
        chapters, so gather a cross-reference set or a reading plan's verses in \
        one call. Use this before quoting or explaining any passage whose exact \
        text isn't already in context — never quote scripture from memory.
        - `action:'search'` — find verses by topic or phrase when you don't \
        know the reference ("verses about anxiety"). Pass `query`, a few \
        content words (stemming matches "loved"/"loving"). `match` controls how \
        words combine: `any` (default, best matches first), `all` (every word), \
        or `phrase` (exact contiguous). Optionally scope to one `book` and cap \
        with `limit`. Results carry each verse's full text and citation — quote \
        them directly; don't re-`read` a verse search already returned.

        `translation` is shared by both actions: omit it so the lookup uses the \
        user's currently selected translation; pass it only when the user names \
        one. Cite as `Book Chapter:Verse` with the full book name.
        """,
        category: .query,
        parameters: [
            LLMToolParameter(
                name: "action",
                type: .string,
                description: "What to do: 'read' to fetch exact passages you name (needs `references`), or 'search' to find verses by topic or phrase (needs `query`).",
                isRequired: true,
                enumValues: ["read", "search"],
                compactDescription: "'read' fetches passages by `references`; 'search' finds verses by `query`."
            ),
            LLMToolParameter(
                name: "references",
                type: .array,
                description: "For action 'read': one or more passages to fetch, each an object with book, chapter, and optional startVerse/endVerse. References may span different books and chapters.",
                isRequired: false,
                valueSchema: .object([
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
                ]),
                compactDescription: "Read action: array of {book, chapter, optional startVerse/endVerse}; may span books/chapters."
            ),
            LLMToolParameter(
                name: "query",
                type: .string,
                description: "For action 'search': the words to search for, e.g. 'anxiety', 'love your enemies', 'shepherd'. By default any word can match; use `match` to require all words or an exact phrase.",
                isRequired: false,
                compactDescription: "Search action: words to find, e.g. 'anxiety'."
            ),
            LLMToolParameter(
                name: "match",
                type: .string,
                description: "For action 'search': how to combine multiple words. 'any' (default): verses containing ANY of the words, best matches first — use for topical searches like 'anxiety hope'. 'all': only verses containing EVERY word. 'phrase': only verses with the exact contiguous phrase, e.g. 'love your enemies'.",
                isRequired: false,
                enumValues: BibleSearchMatchMode.allCases.map(\.rawValue),
                compactDescription: "Search action: combine words — 'any' (default), 'all', or 'phrase' (exact contiguous)."
            ),
            LLMToolParameter(
                name: "book",
                type: .string,
                description: "For action 'search': optional book to limit the search to — a full name like 'Romans' or its 3-letter code ('ROM'). Omit to search the whole Bible.",
                isRequired: false,
                compactDescription: "Search action: limit to one book; omit for the whole Bible."
            ),
            LLMToolParameter(
                name: "limit",
                type: .integer,
                description: "For action 'search': optional maximum number of results (default \(SearchBibleTool.defaultLimit), max \(SearchBibleTool.maxLimit)).",
                isRequired: false,
                compactDescription: "Search action: max results (default \(SearchBibleTool.defaultLimit), max \(SearchBibleTool.maxLimit))."
            ),
            LLMToolParameter(
                name: "translation",
                type: .string,
                description: "Translation code: 'KJV', 'WEB', 'ASV', or 'BSB'. Shared by both actions. Only pass this when the user explicitly names a translation; otherwise OMIT it so the lookup uses the user's currently selected translation.",
                isRequired: false,
                enumValues: BibleTranslation.allCases.map(\.rawValue),
                compactDescription: "Code KJV/WEB/ASV/BSB; omit unless the user names one."
            ),
        ],
        appletId: LookupBibleTool.appletID,
        displayName: "Look up scripture",
        summary: "Reads exact passages or searches verses by content.",
        compactDescription: """
        Look up local scripture. `action:'read'` fetches exact passages — pass \
        `references` (array of {book, chapter, optional startVerse/endVerse}); \
        use it before quoting any passage not already in context, never quote \
        from memory. `action:'search'` finds verses by topic — pass `query` \
        (stemming; `match` any/all/phrase); results carry full text, quote \
        directly. Omit `translation` (uses the user's selected one) unless the \
        user names one.
        """
    )

    /// Build a `ToolRegistration` ready to hand to `ToolRegistry.register(_:)`.
    /// The composition root calls this in each app's bootstrap.
    public static func registration(
        textLoader: any BibleTextLoader,
        searcher: any BibleTextSearching,
        positionRepository: (any BibleReadingPositionRepository)?,
        catalog: BibleBookCatalog = .standard
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(LookupBibleTool(
                textLoader: textLoader,
                searcher: searcher,
                positionRepository: positionRepository,
                catalog: catalog
            )),
            isEnabled: true
        )
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        // `action` is the discriminator. The delegates only read their own
        // keys, so the rest of `input` forwards verbatim — they ignore the
        // stray `action` entry.
        guard case .string(let actionRaw)? = input["action"] else {
            return Self.errorResult("action is required. Use 'read' to fetch exact passages by reference, or 'search' to find verses by topic.")
        }
        switch actionRaw {
        case "read":
            return Self.restamp(try await read.execute(input: input))
        case "search":
            return Self.restamp(try await search.execute(input: input))
        default:
            return Self.errorResult("Unknown action '\(actionRaw)'. Use 'read' or 'search'.")
        }
    }

    /// Re-stamp a delegate's result with this tool's id so the orchestrator
    /// pairs it with the `bible.lookup` call rather than the delegate's old id.
    private static func restamp(_ result: ToolResult) -> ToolResult {
        ToolResult(
            toolID: LookupBibleTool.toolID,
            content: result.content,
            isError: result.isError,
            artifacts: result.artifacts
        )
    }

    private static func errorResult(_ message: String) -> ToolResult {
        ToolResult(toolID: LookupBibleTool.toolID, content: message, isError: true)
    }
}
