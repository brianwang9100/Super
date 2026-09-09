import Foundation
import GRDB
import Testing
@testable import Todo

@Suite("TodoDatabase migrations")
struct TodoDatabaseMigrationTests {

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
                taskId: "t1", labelId: "l1", createdAt: now, updatedAt: now
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
                taskId: "t1", labelId: "l1", createdAt: now, updatedAt: now
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
        await #expect(throws: (any Error).self) {
            try await db.queue.write { db in
                try LabelRecord(id: "b", name: "work", hue: 100, createdAt: now, updatedAt: now).save(db)
            }
        }
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
