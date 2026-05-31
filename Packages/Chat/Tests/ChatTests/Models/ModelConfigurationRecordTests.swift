import Core
import Foundation
import Testing
@testable import Chat

/// Unit coverage for `ModelConfigurationRecord` → Core `ModelConfiguration`
/// projection, focused on the fields the record threads through verbatim.
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

    @Test("searchBackend defaults to nil")
    func defaultsToNilSearchBackend() {
        #expect(record(searchBackend: nil).searchBackend == nil)
    }

    @Test("configuration projection carries searchBackend through")
    func projectsSearchBackend() {
        #expect(record(searchBackend: "native").configuration.searchBackend == "native")
        #expect(record(searchBackend: nil).configuration.searchBackend == nil)
    }
}
