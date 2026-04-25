import Foundation
import GRDB

/// Persistence boundary for `CompactionCheckpointRecord`.
public protocol CompactionCheckpointRepository: Sendable {
    /// The currently live checkpoint for `conversationId`, or nil if the
    /// conversation hasn't been compacted yet.
    func liveCheckpoint(for conversationId: String) async throws -> CompactionCheckpointRecord?
    /// Every checkpoint ever recorded for `conversationId`, newest first.
    func all(for conversationId: String) async throws -> [CompactionCheckpointRecord]
    /// Save a new checkpoint, atomically demoting the prior live one (if
    /// any) for the same conversation to `isLive == false` in the same
    /// write transaction.
    func save(_ record: CompactionCheckpointRecord) async throws
}

/// GRDB-backed `CompactionCheckpointRepository`. The "one live checkpoint
/// per conversation" invariant is enforced inside the `save(_:)`
/// transaction.
public struct GRDBCompactionCheckpointRepository: CompactionCheckpointRepository {
    private let queue: DatabaseQueue

    public init(database: ChatDatabase) {
        self.queue = database.queue
    }

    public func liveCheckpoint(for conversationId: String) async throws -> CompactionCheckpointRecord? {
        try await queue.read { db in
            try CompactionCheckpointRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("isLive") == true)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    public func all(for conversationId: String) async throws -> [CompactionCheckpointRecord] {
        try await queue.read { db in
            try CompactionCheckpointRecord
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    public func save(_ record: CompactionCheckpointRecord) async throws {
        try await queue.write { db in
            if record.isLive {
                try CompactionCheckpointRecord
                    .filter(Column("conversationId") == record.conversationId)
                    .filter(Column("isLive") == true)
                    .filter(Column("id") != record.id)
                    .updateAll(db, Column("isLive").set(to: false))
            }
            try record.save(db)
        }
    }
}
