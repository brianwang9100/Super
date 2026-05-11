import Foundation
import Testing
@testable import Chat

/// Tests for `GRDBToolEnablementRepository` — conformance to Core's
/// `ToolEnablementRepository` and persistence of toggles.
@Suite("GRDBToolEnablementRepository")
struct GRDBToolEnablementRepositoryTests {

    private func makeStore() throws -> (ChatDatabase, GRDBToolEnablementRepository) {
        let db = try ChatDatabase.makeInMemory()
        return (db, GRDBToolEnablementRepository(database: db))
    }

    @Test func isEnabledReturnsNilForUnknownTool() async throws {
        let (_, store) = try makeStore()
        #expect(try await store.isEnabled(toolID: "unknown") == nil)
    }

    @Test func setEnabledUpsertsValue() async throws {
        let (_, store) = try makeStore()
        try await store.setEnabled(toolID: "todo.create", enabled: true)
        #expect(try await store.isEnabled(toolID: "todo.create") == true)

        try await store.setEnabled(toolID: "todo.create", enabled: false)
        #expect(try await store.isEnabled(toolID: "todo.create") == false)
    }

    @Test func allEnabledReturnsEverySavedTool() async throws {
        let (_, store) = try makeStore()
        try await store.setEnabled(toolID: "todo.create", enabled: true)
        try await store.setEnabled(toolID: "calendar.create", enabled: false)
        try await store.setEnabled(toolID: "home.lock", enabled: true)

        let map = try await store.allEnabled()
        #expect(map == [
            "todo.create": true,
            "calendar.create": false,
            "home.lock": true,
        ])
    }
}
