import Foundation
import GRDB

// Create the run and all units atomically. Deletion relies on enabled foreign-key cascades.
public struct GRDBBulkAnnotationLedger: BulkAnnotationLedger {
    private let queue: DatabaseQueue

    public init(database: BibleDatabase) {
        self.queue = database.queue
    }

    public func createRun(
        _ run: BulkAnnotationRunRecord,
        units: [BulkAnnotationRunUnitRecord]
    ) async throws {
        try await queue.write { db in
            try run.insert(db)
            for unit in units {
                try unit.insert(db)
            }
        }
    }

    public func run(id: String) async throws -> BulkAnnotationRunRecord? {
        try await queue.read { db in
            try BulkAnnotationRunRecord.fetchOne(db, key: id)
        }
    }

    public func activeRun() async throws -> BulkAnnotationRunRecord? {
        let activeStatuses = [BulkRunStatus.running.rawValue, BulkRunStatus.paused.rawValue]
        return try await queue.read { db in
            try BulkAnnotationRunRecord
                .filter(activeStatuses.contains(Column("status")))
                .order(Column("createdAt").desc, Column("id").desc)
                .fetchOne(db)
        }
    }

    public func units(runId: String) async throws -> [BulkAnnotationRunUnitRecord] {
        try await queue.read { db in
            try BulkAnnotationRunUnitRecord
                .filter(Column("runId") == runId)
                .order(Column("ordinal").asc)
                .fetchAll(db)
        }
    }

    public func saveRun(_ run: BulkAnnotationRunRecord) async throws {
        try await queue.write { db in
            try run.save(db)
        }
    }

    public func saveUnit(_ unit: BulkAnnotationRunUnitRecord) async throws {
        try await queue.write { db in
            try unit.save(db)
        }
    }

    public func completedRuns() async throws -> [BulkAnnotationRunRecord] {
        try await queue.read { db in
            try BulkAnnotationRunRecord
                .filter(Column("completedAt") != nil)
                .order(Column("completedAt").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    public func deleteRun(id: String) async throws {
        _ = try await queue.write { db in
            try BulkAnnotationRunRecord.deleteOne(db, key: id)
        }
    }

    public func deleteRunsCompleted(before cutoff: Date) async throws {
        _ = try await queue.write { db in
            try BulkAnnotationRunRecord
                .filter(Column("completedAt") != nil && Column("completedAt") < cutoff)
                .deleteAll(db)
        }
    }
}
