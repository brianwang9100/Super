import Core
import Foundation

@testable import Chat

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

    func capturedQueries() -> [String] { queries }
}
