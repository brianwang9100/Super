#if DEBUG
import Core
import Foundation

/// Development-only `WebSearchFulfilling` that returns canned results, so the
/// full web-search flow (cost-gate confirm row, sources pill, Gemini
/// suggestions strip) can be exercised against **any** model — even a real
/// one — with no real search calls or keys. Selected per-model via the
/// `"debug"` search backend (`NativeWebSearch.mockBackendValue`); the host
/// injects it into `ChatSessionStore` in DEBUG builds only.
///
/// Returns the shared `DebugSearchFixture` data. The suggestions strip is
/// emitted only when the query mentions "gemini", mirroring
/// `DebugLLMProvider`'s trigger so both fakes behave the same.
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
