import Foundation
import GRDB

public protocol ToolCallRepository: Sendable {
    func fetch(id: String) async throws -> ToolCallRecord?
    /// Ordered by createdAt, then rowid for timestamp ties.
    func fetchByConversation(_ conversationId: String) async throws -> [ToolCallRecord]
    /// Ordered by createdAt, then rowid for timestamp ties.
    func fetchByMessage(_ messageId: String) async throws -> [ToolCallRecord]
    /// Matches across all conversations.
    func fetchByStatus(_ status: ToolCallStatus) async throws -> [ToolCallRecord]
    func save(_ record: ToolCallRecord) async throws
    /// Atomically update status, result, and completion time.
    /// The caller supplies completedAt so tests can control time.
    func updateStatus(
        id: String,
        status: ToolCallStatus,
        result: String?,
        completedAt: Date?
    ) async throws
}

public struct GRDBToolCallRepository: ToolCallRepository {
    private let queue: DatabaseQueue

    public init(database: ChatDatabase) {
        self.queue = database.queue
    }

    public func fetch(id: String) async throws -> ToolCallRecord? {
        try await queue.read { db in
            try ToolCallRecord.fetchOne(db, key: id)
        }
    }

    public func fetchByConversation(_ conversationId: String) async throws -> [ToolCallRecord] {
        try await queue.read { db in
            try ToolCallRecord
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").asc, Column.rowID.asc)
                .fetchAll(db)
        }
    }

    public func fetchByMessage(_ messageId: String) async throws -> [ToolCallRecord] {
        try await queue.read { db in
            try ToolCallRecord
                .filter(Column("messageId") == messageId)
                .order(Column("createdAt").asc, Column.rowID.asc)
                .fetchAll(db)
        }
    }

    public func fetchByStatus(_ status: ToolCallStatus) async throws -> [ToolCallRecord] {
        try await queue.read { db in
            try ToolCallRecord
                .filter(Column("status") == status.rawValue)
                .order(Column("createdAt").asc, Column.rowID.asc)
                .fetchAll(db)
        }
    }

    public func save(_ record: ToolCallRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }

    public func updateStatus(
        id: String,
        status: ToolCallStatus,
        result: String?,
        completedAt: Date?
    ) async throws {
        try await queue.write { db in
            guard var existing = try ToolCallRecord.fetchOne(db, key: id) else { return }
            existing.status = status
            existing.result = result
            existing.completedAt = completedAt
            try existing.update(db)
        }
    }
}
