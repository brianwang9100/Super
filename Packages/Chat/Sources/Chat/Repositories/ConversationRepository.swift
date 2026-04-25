import Foundation
import GRDB

/// Persistence boundary for `ConversationRecord`. Soft-deleted rows
/// (`deletedAt != nil`) are excluded from `listActive()` but remain in the
/// database until the sync engine confirms server-side deletion.
public protocol ConversationRepository: Sendable {
    /// All non-deleted conversations, newest update first.
    func listActive() async throws -> [ConversationRecord]
    /// One conversation by id, deleted or not.
    func fetch(id: String) async throws -> ConversationRecord?
    /// Insert or update.
    func save(_ record: ConversationRecord) async throws
    /// Mark deleted: sets both `deletedAt` and `updatedAt` to the supplied
    /// timestamp. No-op when the row is already deleted (preserves the
    /// original tombstone time). Caller passes the timestamp so the test
    /// suite can drive deletes against a `Clock`-controlled value.
    func softDelete(id: String, at deletedAt: Date) async throws
    /// Remove the row outright. Cascades to messages and tool calls per
    /// the schema. Use only after sync confirmation.
    func hardDelete(id: String) async throws
}

/// GRDB-backed `ConversationRepository`.
public struct GRDBConversationRepository: ConversationRepository {
    private let queue: DatabaseQueue

    public init(database: ChatDatabase) {
        self.queue = database.queue
    }

    public func listActive() async throws -> [ConversationRecord] {
        try await queue.read { db in
            try ConversationRecord
                .filter(Column("deletedAt") == nil)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> ConversationRecord? {
        try await queue.read { db in
            try ConversationRecord.fetchOne(db, key: id)
        }
    }

    public func save(_ record: ConversationRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }

    public func softDelete(id: String, at deletedAt: Date) async throws {
        try await queue.write { db in
            guard var existing = try ConversationRecord.fetchOne(db, key: id) else { return }
            guard existing.deletedAt == nil else { return }
            existing.deletedAt = deletedAt
            existing.updatedAt = deletedAt
            try existing.update(db)
        }
    }

    public func hardDelete(id: String) async throws {
        _ = try await queue.write { db in
            try ConversationRecord.deleteOne(db, key: id)
        }
    }
}
