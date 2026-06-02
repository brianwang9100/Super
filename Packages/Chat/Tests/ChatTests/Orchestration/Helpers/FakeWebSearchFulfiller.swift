import Core
import Foundation

@testable import Chat

/// Records every `search(query:)` call and returns a scripted
/// `WebSearchResult`, so `ChatSession`'s client-mock search path is testable
/// without `#if DEBUG` / `DebugWebSearchFulfiller`. Mirrors the other
/// `Fake*` orchestration doubles.
actor FakeWebSearchFulfiller: WebSearchFulfilling {
    private let result: WebSearchResult
    private var queries: [String] = []

    init(result: WebSearchResult) {
        self.result = result
    }

    func search(query: String) async -> WebSearchResult {
        queries.append(query)
        return result
    }

    /// The queries passed to `search(query:)`, in call order.
    func capturedQueries() -> [String] { queries }
}
