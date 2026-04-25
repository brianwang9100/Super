import Foundation
import Testing
@testable import Chat

/// Tests for `GRDBSettingRepository` get/set/delete and snapshot listing.
@Suite("GRDBSettingRepository")
struct SettingRepositoryTests {

    private func makeRepo() throws -> GRDBSettingRepository {
        let db = try ChatDatabase.makeInMemory()
        return GRDBSettingRepository(database: db)
    }

    @Test func getReturnsNilForMissingKey() async throws {
        let repo = try makeRepo()
        #expect(try await repo.get("nope") == nil)
    }

    @Test func setIsUpsert() async throws {
        let repo = try makeRepo()
        try await repo.set("systemPrompt", value: "first")
        try await repo.set("systemPrompt", value: "second")
        #expect(try await repo.get("systemPrompt") == "second")
    }

    @Test func deleteRemovesKey() async throws {
        let repo = try makeRepo()
        try await repo.set("accentHue", value: "180")
        try await repo.delete("accentHue")
        #expect(try await repo.get("accentHue") == nil)
    }

    @Test func deleteOnMissingKeyIsNoOp() async throws {
        let repo = try makeRepo()
        try await repo.delete("ghost")
        #expect(try await repo.get("ghost") == nil)
    }

    @Test func allReturnsEveryKeyValuePair() async throws {
        let repo = try makeRepo()
        try await repo.set("a", value: "1")
        try await repo.set("b", value: "2")
        try await repo.set("c", value: "3")

        #expect(try await repo.all() == ["a": "1", "b": "2", "c": "3"])
    }
}
