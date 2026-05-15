import Foundation
import GRDB

/// Persistence boundary for `LabelRecord`. Soft-deleted rows
/// (`deletedAt != nil`) are excluded from `listActive()` but remain in the
/// database until sync confirms server-side deletion.
public protocol LabelRepository: Sendable {
    /// All non-deleted labels, ordered by name (case-insensitive).
    func listActive() async throws -> [LabelRecord]
    /// One label by id, deleted or not.
    func fetch(id: String) async throws -> LabelRecord?
    /// Case-insensitive name lookup among non-deleted rows. Returns `nil`
    /// when no match exists — callers wishing to dedupe-on-create call
    /// this before inserting.
    func findActive(name: String) async throws -> LabelRecord?
    /// Insert or update.
    func save(_ record: LabelRecord) async throws
    /// Mark deleted. Sets both `deletedAt` and `updatedAt` to the supplied
    /// timestamp; no-op when already deleted.
    func softDelete(id: String, at deletedAt: Date) async throws
}

/// GRDB-backed `LabelRepository`.
public struct GRDBLabelRepository: LabelRepository {
    private let queue: DatabaseQueue

    public init(database: TodoDatabase) {
        self.queue = database.queue
    }

    public func listActive() async throws -> [LabelRecord] {
        try await queue.read { db in
            try LabelRecord
                .filter(Column("deletedAt") == nil)
                .order(sql: "lower(name) ASC")
                .fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> LabelRecord? {
        try await queue.read { db in
            try LabelRecord.fetchOne(db, key: id)
        }
    }

    public func findActive(name: String) async throws -> LabelRecord? {
        try await queue.read { db in
            try LabelRecord
                .filter(sql: "lower(name) = ? AND deletedAt IS NULL",
                        arguments: [name.lowercased()])
                .fetchOne(db)
        }
    }

    public func save(_ record: LabelRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }

    public func softDelete(id: String, at deletedAt: Date) async throws {
        try await queue.write { db in
            guard var existing = try LabelRecord.fetchOne(db, key: id) else { return }
            guard existing.deletedAt == nil else { return }
            existing.deletedAt = deletedAt
            existing.updatedAt = deletedAt
            try existing.update(db)
        }
    }
}
