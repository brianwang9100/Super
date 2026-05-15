import Foundation
import GRDB
import Testing
@testable import Todo

/// Tests for `TodoDatabase`'s v1 migration: every table and index exists,
/// foreign-key cascades fire, and the partial unique index on label names
/// is case-insensitive while still allowing soft-deleted-name reuse.
@Suite("TodoDatabase migrations")
struct TodoDatabaseMigrationTests {

    @Test func v1CreatesEverySchemaTable() async throws {
        let db = try TodoDatabase.makeInMemory()
        let names = try await db.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%'
                ORDER BY name
            """)
        }
        #expect(names == ["label", "task", "taskLabel"])
    }

    @Test func v1CreatesExpectedIndexes() async throws {
        let db = try TodoDatabase.makeInMemory()
        let names = try await db.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='index' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
            """)
        }
        #expect(names.contains("task_on_state_priority"))
        #expect(names.contains("task_on_dueAt"))
        #expect(names.contains("task_on_updatedAt"))
        #expect(names.contains("label_unique_name_active"))
        #expect(names.contains("taskLabel_on_labelId"))
    }

    @Test func taskDeleteCascadesToTaskLabel() async throws {
        let db = try TodoDatabase.makeInMemory()
        let now = Date()
        try await db.queue.write { db in
            try TaskRecord(
                id: "t1", title: "x", sortOrder: 0,
                createdAt: now, updatedAt: now
            ).save(db)
            try LabelRecord(
                id: "l1", name: "Work", hue: 200,
                createdAt: now, updatedAt: now
            ).save(db)
            try TaskLabelRecord(
                taskId: "t1", labelId: "l1", createdAt: now
            ).save(db)
        }
        try await db.queue.write { db in
            _ = try TaskRecord.deleteOne(db, key: "t1")
        }
        let joinCount = try await db.queue.read { db in
            try TaskLabelRecord.fetchCount(db)
        }
        #expect(joinCount == 0)
    }

    @Test func labelDeleteCascadesToTaskLabel() async throws {
        let db = try TodoDatabase.makeInMemory()
        let now = Date()
        try await db.queue.write { db in
            try TaskRecord(
                id: "t1", title: "x", sortOrder: 0,
                createdAt: now, updatedAt: now
            ).save(db)
            try LabelRecord(
                id: "l1", name: "Work", hue: 200,
                createdAt: now, updatedAt: now
            ).save(db)
            try TaskLabelRecord(
                taskId: "t1", labelId: "l1", createdAt: now
            ).save(db)
        }
        try await db.queue.write { db in
            _ = try LabelRecord.deleteOne(db, key: "l1")
        }
        let joinCount = try await db.queue.read { db in
            try TaskLabelRecord.fetchCount(db)
        }
        #expect(joinCount == 0)
    }

    @Test func labelNameUniqueIsCaseInsensitive() async throws {
        let db = try TodoDatabase.makeInMemory()
        let now = Date()
        try await db.queue.write { db in
            try LabelRecord(id: "a", name: "Work", hue: 200, createdAt: now, updatedAt: now).save(db)
        }
        var threw = false
        do {
            try await db.queue.write { db in
                try LabelRecord(id: "b", name: "work", hue: 100, createdAt: now, updatedAt: now).save(db)
            }
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test func softDeletedLabelNameMayBeReused() async throws {
        let db = try TodoDatabase.makeInMemory()
        let now = Date()
        try await db.queue.write { db in
            try LabelRecord(id: "a", name: "Work", hue: 200, createdAt: now, updatedAt: now, deletedAt: now).save(db)
            try LabelRecord(id: "b", name: "Work", hue: 100, createdAt: now, updatedAt: now).save(db)
        }
        let count = try await db.queue.read { db in
            try LabelRecord.fetchCount(db)
        }
        #expect(count == 2)
    }
}
