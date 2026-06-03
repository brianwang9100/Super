import Foundation
import GRDB

/// GRDB-backed `BulkAnnotationLedger` over the `bulkAnnotationRun` /
/// `bulkAnnotationRunUnit` tables.
///
/// `createRun(_:units:)` writes the run row and every unit row in one
/// `queue.write` transaction, so a throw mid-insert rolls back to no run at all
/// rather than a run with a partial unit set. `deleteRun` / `deleteRunsCompleted`
/// rely on the unit table's `ON DELETE CASCADE` foreign key (GRDB enables
/// `PRAGMA foreign_keys` by default) to clear children.
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
                // The single-active-run invariant means there's normally one
                // row; `id` is a deterministic tiebreak (matching
                // `completedRuns()`) for the defensive multi-row case.
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
                // `id` is a deterministic tiebreak for the (theoretical) case
                // of two runs sharing a `completedAt`, matching the house
                // style of fully-ordered list queries (`bibleAnnotation`).
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
            // `completedAt < cutoff` already excludes NULL (active) rows in
            // SQL; the explicit IS-NOT-NULL keeps the intent legible.
            try BulkAnnotationRunRecord
                .filter(Column("completedAt") != nil && Column("completedAt") < cutoff)
                .deleteAll(db)
        }
    }
}
