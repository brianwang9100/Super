import Foundation
import GRDB

/// Persistence boundary for `TaskRecord`. Soft-deleted rows are excluded
/// from `listActive()` but remain in the database until sync confirms
/// server-side deletion.
public protocol TaskRepository: Sendable {
    /// All non-deleted tasks, ordered by `createdAt` descending. The
    /// view-model layer applies the user's active filter on top.
    func listActive() async throws -> [TaskRecord]
    /// One task by id, deleted or not.
    func fetch(id: String) async throws -> TaskRecord?
    /// Insert or update.
    func save(_ record: TaskRecord) async throws
    /// Set state and bump `updatedAt`. No-op when the row is missing.
    func setState(id: String, state: TaskState, at updatedAt: Date) async throws
    /// Mark deleted: sets both `deletedAt` and `updatedAt`; no-op when
    /// already deleted.
    func softDelete(id: String, at deletedAt: Date) async throws
    /// Remove the row outright. Cascades to the `taskLabel` join table.
    func hardDelete(id: String) async throws
}

/// GRDB-backed `TaskRepository`.
public struct GRDBTaskRepository: TaskRepository {
    private let queue: DatabaseQueue

    public init(database: TodoDatabase) {
        self.queue = database.queue
    }

    public func listActive() async throws -> [TaskRecord] {
        try await queue.read { db in
            try TaskRecord
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> TaskRecord? {
        try await queue.read { db in
            try TaskRecord.fetchOne(db, key: id)
        }
    }

    public func save(_ record: TaskRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }

    public func setState(id: String, state: TaskState, at updatedAt: Date) async throws {
        try await queue.write { db in
            guard var existing = try TaskRecord.fetchOne(db, key: id) else { return }
            existing.state = state
            existing.updatedAt = updatedAt
            try existing.update(db)
        }
    }

    public func softDelete(id: String, at deletedAt: Date) async throws {
        try await queue.write { db in
            guard var existing = try TaskRecord.fetchOne(db, key: id) else { return }
            guard existing.deletedAt == nil else { return }
            existing.deletedAt = deletedAt
            existing.updatedAt = deletedAt
            try existing.update(db)
        }
    }

    public func hardDelete(id: String) async throws {
        _ = try await queue.write { db in
            try TaskRecord.deleteOne(db, key: id)
        }
    }
}
