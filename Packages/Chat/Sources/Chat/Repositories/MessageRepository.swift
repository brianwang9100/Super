import Foundation
import GRDB

public protocol MessageRepository: Sendable {
    /// Ordered by createdAt, then rowid to preserve insertion order when timestamps tie.
    func fetchAll(conversationId: String) async throws -> [MessageRecord]
    func fetch(id: String) async throws -> MessageRecord?
    /// Check for a user message without materializing the transcript.
    func hasUserMessage(conversationId: String) async throws -> Bool
    func save(_ record: MessageRecord) async throws
    /// Delete a contiguous tail in one statement, cascading to tool calls; empty IDs are a no-op.
    /// Do not leave transcript holes: later assistant/tool messages may depend on earlier turns.
    func delete(ids: [String]) async throws
    /// Delete messages and their tool calls, preserving the conversation.
    func deleteAll(conversationId: String) async throws
}

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
