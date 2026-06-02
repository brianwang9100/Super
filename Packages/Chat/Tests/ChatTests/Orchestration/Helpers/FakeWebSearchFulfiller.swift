import Core
import Foundation

@testable import Chat

/// Records every `search(query:)` call and returns a scripted
/// `MockSearchResult`, so `ChatSession`'s client-mock search path is testable
/// without `#if DEBUG` / `DebugWebSearchFulfiller`. Mirrors the other
/// `Fake*` orchestration doubles.
actor FakeWebSearchFulfiller: WebSearchFulfilling {
    private let result: MockSearchResult
    private var queries: [String] = []

    init(result: MockSearchResult) {
        self.result = result
    }

    func search(query: String) async -> MockSearchResult {
        queries.append(query)
        return result
    }

    /// The queries passed to `search(query:)`, in call order.
    func capturedQueries() -> [String] { queries }
}
