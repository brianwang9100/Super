#if DEBUG
import Core
import Foundation

public struct DebugWebSearchFulfiller: WebSearchFulfilling {
    public init() {}

    public func search(query: String) async -> WebSearchResult {
        WebSearchResult(
            findings: DebugSearchFixture.findings,
            sources: DebugSearchFixture.citations,
            searchSuggestionsHTML: query.localizedCaseInsensitiveContains("gemini")
                ? DebugSearchFixture.suggestionsHTML
                : nil
        )
    }
}
#endif
