import Foundation
import Testing
@testable import Todo

/// Tests for `GRDBLabelRepository`: active-row filtering, case-insensitive
/// lookup, and soft-delete semantics, all against an in-memory database.
@Suite("GRDBLabelRepository")
struct LabelRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepo() throws -> GRDBLabelRepository {
        let db = try TodoDatabase.makeInMemory()
        return GRDBLabelRepository(database: db)
    }

    @Test func listActiveExcludesSoftDeletedAndSortsCaseInsensitive() async throws {
        let repo = try makeRepo()
        try await repo.save(LabelRecord(id: "1", name: "work", hue: 200, createdAt: now, updatedAt: now))
        try await repo.save(LabelRecord(id: "2", name: "Admin", hue: 280, createdAt: now, updatedAt: now))
        try await repo.save(LabelRecord(id: "3", name: "gone", hue: 0, createdAt: now, updatedAt: now, deletedAt: now))

        let active = try await repo.listActive()
        #expect(active.map(\.name) == ["Admin", "work"])
    }

    @Test func findActiveIsCaseInsensitive() async throws {
        let repo = try makeRepo()
        try await repo.save(LabelRecord(id: "1", name: "Work", hue: 200, createdAt: now, updatedAt: now))
        #expect(try await repo.findActive(name: "work")?.id == "1")
        #expect(try await repo.findActive(name: "WORK")?.id == "1")
        #expect(try await repo.findActive(name: "play") == nil)
    }

    @Test func findActiveIgnoresSoftDeleted() async throws {
        let repo = try makeRepo()
        try await repo.save(LabelRecord(id: "1", name: "Work", hue: 200, createdAt: now, updatedAt: now, deletedAt: now))
        #expect(try await repo.findActive(name: "work") == nil)
    }

    @Test func softDeleteSetsDeletedAtAndBumpsUpdatedAt() async throws {
        let repo = try makeRepo()
        try await repo.save(LabelRecord(id: "1", name: "Work", hue: 200, createdAt: now, updatedAt: now))
        let cutoff = now.addingTimeInterval(60)
        try await repo.softDelete(id: "1", at: cutoff)
        let row = try await repo.fetch(id: "1")
        #expect(row?.deletedAt == cutoff)
        #expect(row?.updatedAt == cutoff)
    }

    @Test func softDeleteIsNoOpWhenAlreadyDeleted() async throws {
        let repo = try makeRepo()
        try await repo.save(LabelRecord(id: "1", name: "Work", hue: 200, createdAt: now, updatedAt: now, deletedAt: now))
        try await repo.softDelete(id: "1", at: now.addingTimeInterval(60))
        let row = try await repo.fetch(id: "1")
        #expect(row?.deletedAt == now)
    }

    @Test func saveUpsertsExistingRow() async throws {
        let repo = try makeRepo()
        try await repo.save(LabelRecord(id: "1", name: "Work", hue: 200, createdAt: now, updatedAt: now))
        try await repo.save(LabelRecord(id: "1", name: "Workish", hue: 250, createdAt: now, updatedAt: now.addingTimeInterval(60)))
        let active = try await repo.listActive()
        #expect(active.count == 1)
        #expect(active.first?.name == "Workish")
        #expect(active.first?.hue == 250)
    }
}
