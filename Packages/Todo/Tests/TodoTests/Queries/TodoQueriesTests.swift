import Foundation
import Testing
@testable import Todo

/// Tests for the GRDBQuery requests `ActiveTasksRequest` / `ActiveLabelsRequest`.
/// Each `fetch(_:)` is exercised directly against an in-memory database —
/// the `@Query` observation wrapper is covered at the view layer.
@Suite("Todo queries")
struct TodoQueriesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func task(_ id: String, at: Date, deletedAt: Date? = nil) -> TaskRecord {
        TaskRecord(
            id: id, title: id,
            sortOrder: 0, createdAt: at, updatedAt: at,
            deletedAt: deletedAt
        )
    }

    private func label(_ id: String, _ name: String, deletedAt: Date? = nil) -> LabelRecord {
        LabelRecord(id: id, name: name, hue: 200, createdAt: now, updatedAt: now, deletedAt: deletedAt)
    }

    @Test func activeTasksRequestReturnsTasksNewestFirstWithLabels() async throws {
        let db = try TodoDatabase.makeInMemory()
        try await db.queue.write { db in
            try task("old", at: now).save(db)
            try task("new", at: now.addingTimeInterval(60)).save(db)
            try label("L1", "Work").save(db)
            try TaskLabelRecord(taskId: "new", labelId: "L1", createdAt: now, updatedAt: now).save(db)
        }
        let rows = try await db.queue.read { try ActiveTasksRequest().fetch($0) }
        #expect(rows.map(\.id) == ["new", "old"])
        #expect(rows.first?.labels.map(\.name) == ["Work"])
        #expect(rows.last?.labels.isEmpty == true)
    }

    @Test func activeTasksRequestExcludesSoftDeletedTasks() async throws {
        let db = try TodoDatabase.makeInMemory()
        try await db.queue.write { db in
            try task("live", at: now).save(db)
            try task("gone", at: now, deletedAt: now).save(db)
        }
        let rows = try await db.queue.read { try ActiveTasksRequest().fetch($0) }
        #expect(rows.map(\.id) == ["live"])
    }

    @Test func activeTasksRequestExcludesSoftDeletedLabels() async throws {
        let db = try TodoDatabase.makeInMemory()
        try await db.queue.write { db in
            try task("T1", at: now).save(db)
            try label("L1", "Work", deletedAt: now).save(db)
            try TaskLabelRecord(taskId: "T1", labelId: "L1", createdAt: now, updatedAt: now).save(db)
        }
        let rows = try await db.queue.read { try ActiveTasksRequest().fetch($0) }
        #expect(rows.first?.labels.isEmpty == true)
    }

    @Test func activeLabelsRequestReturnsActiveLabelsSortedCaseInsensitive() async throws {
        let db = try TodoDatabase.makeInMemory()
        try await db.queue.write { db in
            try label("L1", "work").save(db)
            try label("L2", "Admin").save(db)
            try label("L3", "gone", deletedAt: now).save(db)
        }
        let labels = try await db.queue.read { try ActiveLabelsRequest().fetch($0) }
        #expect(labels.map(\.name) == ["Admin", "work"])
    }
}
