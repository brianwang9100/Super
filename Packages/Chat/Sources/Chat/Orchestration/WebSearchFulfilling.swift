import Core
import Foundation

public struct WebSearchResult: Sendable, Equatable {
    public let findings: String
    public let sources: [SourceCitation]
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

/// Resolves approved client-side searches. A missing fulfiller makes unsupported backends decline.
public protocol WebSearchFulfilling: Sendable {
    /// Fold failures into an empty/error result so the turn loop can continue.
    func search(query: String) async -> WebSearchResult
}
