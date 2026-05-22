import Foundation
import GRDB

/// Persistence boundary for `MessageRecord`. The session orchestrator
/// writes only on `.messageCompleted` (per ADR-BB-003 in
/// `docs/Chat/ARCHITECTURE.md`), so this protocol intentionally exposes no
/// "append delta" surface.
///
/// Per-message delete (`delete(ids:)`) exists to support Regenerate —
/// rewinding the transcript to an earlier assistant turn — and is intended
/// to be called with a contiguous tail of rows ending at the conversation's
/// latest message. Deleting a row from the middle of a conversation would
/// break the LLM (Large Language Model) history contract; callers are
/// responsible for collecting the right id set. `deleteAll(conversationId:)`
/// drops a whole conversation's history; the `ConversationRecord` cascade
/// wipes everything for a deleted conversation.
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
    /// history projection. Implementations should avoid materializing the
    /// full conversation: a `SELECT 1 ... LIMIT 1` is the intended shape.
    ///
    /// Cost with the current `message_on_conversationId_createdAt` index:
    /// O(1) for the user-present case (the user row is always the earliest
    /// message in a conversation, so the planner stops after the first
    /// match). Degrades to an O(n) scan of the conversation for the
    /// no-match case — reachable only on a stale Retry of a brand-new or
    /// all-tool-rows conversation, which is uncommon. A `(conversationId,
    /// role)` covering index would make both paths O(1) but isn't worth
    /// the migration today.
    func hasUserMessage(conversationId: String) async throws -> Bool
    /// Insert or update.
    func save(_ record: MessageRecord) async throws
    /// Delete the messages with the given ids in a single statement.
    /// Tool calls cascade with the message rows. Empty `ids` is a no-op.
    /// See the protocol doc for the contiguous-tail constraint.
    func delete(ids: [String]) async throws
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
            // `.limit(1).fetchOne` translates to `SELECT * ... LIMIT 1`.
            // The SQLite planner uses `message_on_conversationId_createdAt`
            // to seek to the conversation's first row and walks by
            // `createdAt`, stopping at the first `role == .user` match.
            // The user row is always the earliest message in a conversation,
            // so the present-case is O(1); the absent-case (used only on
            // stale Retry against an all-tool-rows or empty conversation)
            // scans every row in the conversation. See the protocol doc
            // for why the migration to a `(conversationId, role)` covering
            // index isn't worth it today.
            try MessageRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("role") == MessageRole.user.rawValue)
                .limit(1)
                .fetchOne(db) != nil
        }
    }

    public func save(_ record: MessageRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }

    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await queue.write { db in
            try MessageRecord
                .filter(ids.contains(Column("id")))
                .deleteAll(db)
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
