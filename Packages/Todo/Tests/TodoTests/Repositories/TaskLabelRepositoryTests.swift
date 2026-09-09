import Foundation
import GRDB
import Testing
@testable import Todo

/// Tests for `GRDBTaskLabelRepository`: the set-replacement semantics of
/// `setLabels` and the soft-delete-aware bulk lookup.
@Suite("GRDBTaskLabelRepository")
struct TaskLabelRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeAll() throws
        -> (TodoDatabase, GRDBTaskRepository, GRDBLabelRepository, GRDBTaskLabelRepository) {
        let db = try TodoDatabase.makeInMemory()
        return (
            db,
            GRDBTaskRepository(database: db),
            GRDBLabelRepository(database: db),
            GRDBTaskLabelRepository(database: db)
        )
    }

    private func makeRepos() throws
        -> (GRDBTaskRepository, GRDBLabelRepository, GRDBTaskLabelRepository) {
        let (_, taskRepo, labelRepo, joinRepo) = try makeAll()
        return (taskRepo, labelRepo, joinRepo)
    }

    private func task(_ id: String) -> TaskRecord {
        TaskRecord(id: id, title: id, sortOrder: 0, createdAt: now, updatedAt: now)
    }

    private func label(_ id: String, _ name: String) -> LabelRecord {
        LabelRecord(id: id, name: name, hue: 200, createdAt: now, updatedAt: now)
    }

    @Test func setLabelsInsertsRowsForNewLabels() async throws {
        let (taskRepo, labelRepo, joinRepo) = try makeRepos()
        try await taskRepo.save(task("t1"))
        try await labelRepo.save(label("l1", "Work"))
        try await labelRepo.save(label("l2", "Home"))

        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1", "l2"], at: now)
        let labels = try await joinRepo.labels(forTaskId: "t1")
        #expect(labels.map(\.id).sorted() == ["l1", "l2"])
    }

    @Test func setLabelsRemovesRowsNotInNewSet() async throws {
        let (taskRepo, labelRepo, joinRepo) = try makeRepos()
        try await taskRepo.save(task("t1"))
        try await labelRepo.save(label("l1", "Work"))
        try await labelRepo.save(label("l2", "Home"))
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1", "l2"], at: now)

        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l2"], at: now)
        let labels = try await joinRepo.labels(forTaskId: "t1")
        #expect(labels.map(\.id) == ["l2"])
    }

    @Test func setLabelsWithEmptyArrayRemovesEverything() async throws {
        let (taskRepo, labelRepo, joinRepo) = try makeRepos()
        try await taskRepo.save(task("t1"))
        try await labelRepo.save(label("l1", "Work"))
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1"], at: now)
        try await joinRepo.setLabels(taskId: "t1", labelIds: [], at: now)
        #expect(try await joinRepo.labels(forTaskId: "t1").isEmpty)
    }

    @Test func bulkLookupGroupsByTaskId() async throws {
        let (taskRepo, labelRepo, joinRepo) = try makeRepos()
        try await taskRepo.save(task("t1"))
        try await taskRepo.save(task("t2"))
        try await taskRepo.save(task("unrequested"))
        try await labelRepo.save(label("l1", "Work"))
        try await labelRepo.save(label("l2", "Home"))
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1", "l2"], at: now)
        try await joinRepo.setLabels(taskId: "t2", labelIds: ["l2"], at: now)
        try await joinRepo.setLabels(taskId: "unrequested", labelIds: ["l1"], at: now)

        let bulk = try await joinRepo.labels(forTaskIds: ["t1", "t2", "missing"])
        #expect(Set(bulk.keys) == ["t1", "t2"])
        #expect(Set(bulk["t1"]?.map(\.id) ?? []) == Set(["l1", "l2"]))
        #expect(bulk["t2"]?.map(\.id) == ["l2"])
        #expect(try await joinRepo.labels(forTaskIds: []).isEmpty)
    }

    @Test func duplicateLabelsAndRepeatedReplacementPreserveRowsAndTimestamps() async throws {
        let (database, taskRepo, labelRepo, joinRepo) = try makeAll()
        try await taskRepo.save(task("t1"))
        try await labelRepo.save(label("l1", "Work"))
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1", "l1"], at: now)
        let original = try await database.queue.read { try TaskLabelRecord.fetchAll($0) }
        #expect(original == [TaskLabelRecord(taskId: "t1", labelId: "l1", createdAt: now, updatedAt: now)])

        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1", "l1"], at: now.addingTimeInterval(60))
        let repeated = try await database.queue.read { try TaskLabelRecord.fetchAll($0) }
        #expect(repeated == original)
    }

    @Test func failedReplacementRollsBackInsertedLabelsAndPreservesOtherTasks() async throws {
        let (database, taskRepo, labelRepo, joinRepo) = try makeAll()
        for id in ["t1", "t2"] { try await taskRepo.save(task(id)) }
        try await labelRepo.save(label("l1", "Work"))
        try await labelRepo.save(label("l2", "Home"))
        for id in ["t1", "t2"] {
            try await joinRepo.setLabels(taskId: id, labelIds: ["l1"], at: now)
        }
        let original = try await database.queue.read {
            try TaskLabelRecord.order(Column("taskId"), Column("labelId")).fetchAll($0)
        }
        try await database.queue.write { db in
            // setLabels inserts l2 before removing l1. Fail that removal so
            // this test proves the preceding insert is rolled back too.
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_label_removal BEFORE DELETE ON taskLabel
                WHEN OLD.taskId = 't1' AND OLD.labelId = 'l1'
                BEGIN SELECT RAISE(ABORT, 'replacement rejected'); END
                """)
        }
        do {
            try await joinRepo.setLabels(taskId: "t1", labelIds: ["l2"], at: now.addingTimeInterval(60))
            Issue.record("Expected the trigger to reject the replacement")
        } catch let error as DatabaseError {
            #expect(error.extendedResultCode == .SQLITE_CONSTRAINT_TRIGGER)
            #expect(error.message == "replacement rejected")
        }
        let afterFailure = try await database.queue.read {
            try TaskLabelRecord.order(Column("taskId"), Column("labelId")).fetchAll($0)
        }
        #expect(afterFailure == original)

        try await database.queue.write { try $0.execute(sql: "DROP TRIGGER reject_label_removal") }
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l2"], at: now.addingTimeInterval(60))
        #expect(try await joinRepo.labels(forTaskId: "t1").map(\.id) == ["l2"])
        #expect(try await joinRepo.labels(forTaskId: "t2").map(\.id) == ["l1"])
    }

    @Test func bulkLookupSortsLabelsByNameCaseInsensitive() async throws {
        let (taskRepo, labelRepo, joinRepo) = try makeRepos()
        try await taskRepo.save(task("t1"))
        try await labelRepo.save(label("l1", "work"))
        try await labelRepo.save(label("l2", "Admin"))
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1", "l2"], at: now)
        let labels = try await joinRepo.labels(forTaskId: "t1")
        #expect(labels.map(\.name) == ["Admin", "work"])
    }

    @Test func bulkLookupExcludesSoftDeletedJoinRows() async throws {
        let (db, taskRepo, labelRepo, joinRepo) = try makeAll()
        try await taskRepo.save(task("t1"))
        try await labelRepo.save(label("l1", "Work"))
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1"], at: now)
        // Tombstone the join row directly — simulates the future sync
        // write path, which will soft-delete instead of hard-delete.
        try await db.queue.write { db in
            try TaskLabelRecord(
                taskId: "t1", labelId: "l1",
                createdAt: now, updatedAt: now, deletedAt: now
            ).save(db)
        }
        let bulk = try await joinRepo.labels(forTaskIds: ["t1"])
        #expect(bulk["t1"] == nil)
    }

    @Test func setLabelsTreatsSoftDeletedJoinRowAsAbsent() async throws {
        let (db, taskRepo, labelRepo, joinRepo) = try makeAll()
        try await taskRepo.save(task("t1"))
        try await labelRepo.save(label("l1", "Work"))
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1"], at: now)
        try await db.queue.write { db in
            try TaskLabelRecord(
                taskId: "t1", labelId: "l1",
                createdAt: now, updatedAt: now, deletedAt: now
            ).save(db)
        }
        // A soft-deleted join row counts as absent, so `setLabels` must
        // re-attach the label rather than treating it as already present.
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1"], at: now.addingTimeInterval(60))
        let labels = try await joinRepo.labels(forTaskId: "t1")
        #expect(labels.map(\.id) == ["l1"])
    }

    @Test func bulkLookupIgnoresSoftDeletedLabels() async throws {
        let (taskRepo, labelRepo, joinRepo) = try makeRepos()
        try await taskRepo.save(task("t1"))
        try await labelRepo.save(label("l1", "Work"))
        try await joinRepo.setLabels(taskId: "t1", labelIds: ["l1"], at: now)
        try await labelRepo.softDelete(id: "l1", at: now)
        let bulk = try await joinRepo.labels(forTaskIds: ["t1"])
        #expect(bulk["t1"] == nil)
    }
}
