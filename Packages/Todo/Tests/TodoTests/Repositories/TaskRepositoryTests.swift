import Foundation
import Testing
@testable import Todo

/// Tests for `GRDBTaskRepository`: active-row filtering and ordering,
/// state transitions, and the soft- vs hard-delete distinction.
@Suite("GRDBTaskRepository")
struct TaskRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepo() throws -> GRDBTaskRepository {
        let db = try TodoDatabase.makeInMemory()
        return GRDBTaskRepository(database: db)
    }

    private func task(
        _ id: String,
        title: String = "x",
        at: Date? = nil,
        state: TaskState = .open,
        deletedAt: Date? = nil
    ) -> TaskRecord {
        let stamp = at ?? now
        return TaskRecord(
            id: id, title: title,
            sortOrder: 0, createdAt: stamp, updatedAt: stamp,
            priority: .normal, state: state, deletedAt: deletedAt
        )
    }

    @Test func listActiveExcludesSoftDeletedAndSortsByCreatedAtDesc() async throws {
        let repo = try makeRepo()
        try await repo.save(task("a", at: now))
        try await repo.save(task("b", at: now.addingTimeInterval(60)))
        try await repo.save(task("c", at: now.addingTimeInterval(-60), deletedAt: now))
        let active = try await repo.listActive()
        #expect(active.map(\.id) == ["b", "a"])
    }

    @Test func setStateBumpsUpdatedAt() async throws {
        let repo = try makeRepo()
        try await repo.save(task("a"))
        let cutoff = now.addingTimeInterval(120)
        try await repo.setState(id: "a", state: .done, at: cutoff)
        let row = try await repo.fetch(id: "a")
        #expect(row?.state == .done)
        #expect(row?.updatedAt == cutoff)
    }

    @Test func setStateIsNoOpWhenMissing() async throws {
        let repo = try makeRepo()
        try await repo.setState(id: "ghost", state: .done, at: now)
        #expect(try await repo.fetch(id: "ghost") == nil)
    }

    @Test func softDeleteSetsDeletedAtAndBumpsUpdatedAt() async throws {
        let repo = try makeRepo()
        try await repo.save(task("a"))
        let cutoff = now.addingTimeInterval(120)
        try await repo.softDelete(id: "a", at: cutoff)
        let row = try await repo.fetch(id: "a")
        #expect(row?.deletedAt == cutoff)
        #expect(row?.updatedAt == cutoff)
    }

    @Test func hardDeleteRemovesRow() async throws {
        let repo = try makeRepo()
        try await repo.save(task("a"))
        try await repo.hardDelete(id: "a")
        #expect(try await repo.fetch(id: "a") == nil)
    }

    @Test func saveUpsertsExistingRow() async throws {
        let repo = try makeRepo()
        try await repo.save(task("a", title: "old"))
        try await repo.save(task("a", title: "new", at: now.addingTimeInterval(60)))
        let active = try await repo.listActive()
        #expect(active.count == 1)
        #expect(active.first?.title == "new")
    }
}
