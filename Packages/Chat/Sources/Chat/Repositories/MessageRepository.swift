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
    /// All messages in `conversationId`, ordered by `createdAt` ascending
    /// with `rowid` as tiebreaker — the order an LLM (Large Language Model)
    /// provider expects. The `rowid` tiebreaker matters because the
    /// orchestrator can write several rows inside a single turn and a wall
    /// clock can return ties; rowid resolves to insertion order.
    func fetchAll(conversationId: String) async throws -> [MessageRecord]
    /// One message by id.
    func fetch(id: String) async throws -> MessageRecord?
    /// Cheap "does this conversation have at least one user-role message"
    /// predicate. Used by the retry path to decide whether re-running the
    /// LLM loop is meaningful before paying for a full `fetchAll` +
    /// history projection. Implementations should be O(1) — a SELECT 1
    /// with LIMIT, not a full materialization.
    func hasUserMessage(conversationId: String) async throws -> Bool
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
                .order(Column("createdAt").asc, Column.rowID.asc)
                .fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> MessageRecord? {
        try await queue.read { db in
            try MessageRecord.fetchOne(db, key: id)
        }
    }

    public func hasUserMessage(conversationId: String) async throws -> Bool {
        try await queue.read { db in
            try MessageRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("role") == MessageRole.user.rawValue)
                .fetchCount(db) > 0
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
