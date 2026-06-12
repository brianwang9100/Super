import Foundation
import GRDB

/// Persistence boundary for `ToolCallRecord`.
public protocol ToolCallRepository: Sendable {
    /// One tool call by id.
    func fetch(id: String) async throws -> ToolCallRecord?
    /// Every tool call attached to `conversationId`, ordered by
    /// `createdAt` ascending with `rowid` as tiebreaker (so multiple calls
    /// written in one turn surface in their issue order even when the
    /// clock ties them).
    func fetchByConversation(_ conversationId: String) async throws -> [ToolCallRecord]
    /// Every tool call triggered by a single assistant message, in the
    /// order they were issued (`createdAt` ascending, `rowid` tiebreaker).
    func fetchByMessage(_ messageId: String) async throws -> [ToolCallRecord]
    /// Every tool call in a given lifecycle state across all conversations.
    /// Used by `ChatSessionStore.recoverInterruptedToolCalls()` — the launch
    /// sweep that resolves calls stranded at a non-terminal status by a
    /// crash or force-quit.
    func fetchByStatus(_ status: ToolCallStatus) async throws -> [ToolCallRecord]
    /// Insert or update.
    func save(_ record: ToolCallRecord) async throws
    /// Atomic status (and optional result) transition. Setting
    /// `completedAt` is the caller's job — pass it explicitly so the row
    /// reflects the same time the executor reported back.
    func updateStatus(
        id: String,
        status: ToolCallStatus,
        result: String?,
        completedAt: Date?
    ) async throws
}

/// GRDB-backed `ToolCallRepository`.
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
