import Core
import Foundation
import Testing
@testable import Chat

@Suite("ModelConfigurationRecord projection")
struct ModelConfigurationRecordTests {
    private func record(searchBackend: String?) -> ModelConfigurationRecord {
        ModelConfigurationRecord(
            id: "r1",
            name: "Test",
            baseURL: URL(string: "https://api.example.com/v1"),
            apiKeyRef: "ref",
            modelId: "m",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            searchBackend: searchBackend
        )
    }

    @Test("configuration projection carries searchBackend through")
    func projectsSearchBackend() {
        #expect(record(searchBackend: "native").configuration.searchBackend == "native")
        #expect(record(searchBackend: nil).configuration.searchBackend == nil)
    }
}
