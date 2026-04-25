import Foundation
import GRDB

/// Persistence boundary for `MessageRecord`. The session orchestrator
/// writes only on `.messageCompleted` (per ADR-BB-003 in
/// `docs/Chat/ARCHITECTURE.md`), so this protocol intentionally exposes no
/// "append delta" surface.
///
/// No per-message delete by design: removing one message mid-conversation
/// would break the LLM (Large Language Model) history contract, and
/// soft-deleting a single row has no Chat product surface ("undo a sent
/// message" doesn't exist). Use `deleteAll(conversationId:)` to drop a
/// whole conversation's history, or rely on the `ConversationRecord`
/// cascade to wipe everything for a deleted conversation.
public protocol MessageRepository: Sendable {
    /// All messages in `conversationId`, ordered by `createdAt` ascending —
    /// the order an LLM (Large Language Model) provider expects.
    func fetchAll(conversationId: String) async throws -> [MessageRecord]
    /// One message by id.
    func fetch(id: String) async throws -> MessageRecord?
    /// Insert or update.
    func save(_ record: MessageRecord) async throws
    /// Drop every message for the conversation. Tool calls cascade with
    /// the message rows; the conversation itself is untouched.
    func deleteAll(conversationId: String) async throws
}

/// GRDB-backed `MessageRepository`.
public struct GRDBMessageRepository: MessageRepository {
    private let queue: DatabaseQueue

    public init(database: ChatDatabase) {
        self.queue = database.queue
    }

    public func fetchAll(conversationId: String) async throws -> [MessageRecord] {
        try await queue.read { db in
            try MessageRecord
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> MessageRecord? {
        try await queue.read { db in
            try MessageRecord.fetchOne(db, key: id)
        }
    }

    public func save(_ record: MessageRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }

    public func deleteAll(conversationId: String) async throws {
        _ = try await queue.write { db in
            try MessageRecord
                .filter(Column("conversationId") == conversationId)
                .deleteAll(db)
        }
    }
}
