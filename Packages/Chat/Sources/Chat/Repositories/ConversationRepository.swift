import Foundation
import GRDB

public protocol ConversationRepository: Sendable {
    /// All non-deleted conversations, newest update first.
    func listActive() async throws -> [ConversationRecord]
    /// Newest update first. Request limit + 1 to detect overflow beyond a displayed cap.
    func listActiveRecent(limit: Int) async throws -> [ConversationRecord]
    /// Includes soft-deleted rows.
    func fetch(id: String) async throws -> ConversationRecord?
    func save(_ record: ConversationRecord) async throws
    /// Set deletedAt and updatedAt; preserve the original tombstone if already deleted.
    func softDelete(id: String, at deletedAt: Date) async throws
    /// Delete permanently, cascading to messages and tool calls.
    func hardDelete(id: String) async throws
}

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

    public func listActiveRecent(limit: Int) async throws -> [ConversationRecord] {
        try await queue.read { db in
            try ConversationRecord
                .filter(Column("deletedAt") == nil)
                .order(Column("updatedAt").desc)
                .limit(limit)
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
