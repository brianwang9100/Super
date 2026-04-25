import Foundation
import Testing
@testable import Chat

/// Tests for `GRDBConversationRepository` listing, soft-delete, and
/// hard-delete behavior.
@Suite("GRDBConversationRepository")
struct ConversationRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepo() throws -> (ChatDatabase, GRDBConversationRepository) {
        let db = try ChatDatabase.makeInMemory()
        return (db, GRDBConversationRepository(database: db))
    }

    @Test func listActiveExcludesSoftDeletedAndOrdersByUpdatedAtDesc() async throws {
        let (_, repo) = try makeRepo()
        try await repo.save(ConversationRecord(
            id: "a", title: "First", createdAt: now, updatedAt: now
        ))
        try await repo.save(ConversationRecord(
            id: "b", title: "Newest", createdAt: now, updatedAt: now.addingTimeInterval(60)
        ))
        try await repo.save(ConversationRecord(
            id: "c", title: "Deleted", createdAt: now, updatedAt: now, deletedAt: now
        ))

        let active = try await repo.listActive()
        #expect(active.map(\.id) == ["b", "a"])
    }

    @Test func softDeleteSetsDeletedAtAndBumpsUpdatedAt() async throws {
        let (_, repo) = try makeRepo()
        try await repo.save(ConversationRecord(
            id: "x", title: "Bye", createdAt: now, updatedAt: now
        ))

        let cutoff = now.addingTimeInterval(120)
        try await repo.softDelete(id: "x", at: cutoff)

        let row = try await repo.fetch(id: "x")
        #expect(row?.deletedAt == cutoff)
        #expect(row?.updatedAt == cutoff)
    }

    @Test func softDeleteIsNoOpWhenAlreadyDeleted() async throws {
        let (_, repo) = try makeRepo()
        let original = ConversationRecord(
            id: "x", title: "Bye", createdAt: now, updatedAt: now, deletedAt: now
        )
        try await repo.save(original)

        try await repo.softDelete(id: "x", at: now.addingTimeInterval(60))

        let row = try await repo.fetch(id: "x")
        #expect(row?.deletedAt == now)
    }

    @Test func hardDeleteRemovesRow() async throws {
        let (_, repo) = try makeRepo()
        try await repo.save(ConversationRecord(
            id: "x", title: "Gone", createdAt: now, updatedAt: now
        ))
        try await repo.hardDelete(id: "x")
        #expect(try await repo.fetch(id: "x") == nil)
    }

    @Test func saveUpsertsExistingRow() async throws {
        let (_, repo) = try makeRepo()
        try await repo.save(ConversationRecord(
            id: "x", title: "Old", createdAt: now, updatedAt: now
        ))
        try await repo.save(ConversationRecord(
            id: "x", title: "New", createdAt: now, updatedAt: now.addingTimeInterval(60)
        ))
        let active = try await repo.listActive()
        #expect(active.count == 1)
        #expect(active.first?.title == "New")
    }
}
