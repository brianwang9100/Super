import Core
import Foundation

/// Result of a client-side (non-native) web search: the model-readable
/// findings plus the citations to surface, mirroring what a native provider
/// streams as `.citations` (and optionally `.searchSuggestionsHTML`).
public struct MockSearchResult: Sendable, Equatable {
    /// Text fed back to the model as the search tool's result so it can
    /// ground its answer. Reads like a short findings summary.
    public let findings: String
    /// Citations lifted onto the assistant's grounded answer message — the
    /// sources pill renders these.
    public let sources: [SourceCitation]
    /// Optional Google-style suggestions HTML, exercising the always-visible
    /// suggestions strip; `nil` for backends that don't produce one.
    public let searchSuggestionsHTML: String?

    public init(
        findings: String,
        sources: [SourceCitation],
        searchSuggestionsHTML: String? = nil
    ) {
        self.findings = findings
        self.sources = sources
        self.searchSuggestionsHTML = searchSuggestionsHTML
    }
}

/// Fulfills a web search *client-side* — used by `ChatSession` to resolve an
/// approved search for a non-native (`searchBackend != "native"`) model
/// without asking the model's own provider to search. Today the only
/// conformer is the DEBUG `DebugWebSearchFulfiller` (the `"debug"` mock
/// backend); the standalone Tavily/Brave engine would conform here too.
///
/// Injected into `ChatSession` (and `ChatSessionStore`) as an optional seam:
/// `nil` in Release means a stray `"debug"` backend resolves as a declined
/// search rather than crashing. A `Fake` conformer keeps the orchestration
/// testable without `#if DEBUG`.
public protocol WebSearchFulfilling: Sendable {
    /// Run the search for `query` and return the findings + citations to
    /// surface. Non-throwing: a fulfiller folds any failure into an
    /// empty/error `MockSearchResult` so the turn loop always gets a result.
    func search(query: String) async -> MockSearchResult
}
