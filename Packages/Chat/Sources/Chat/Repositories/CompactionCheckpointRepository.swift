import Foundation
import GRDB

public protocol CompactionCheckpointRepository: Sendable {
    func liveCheckpoint(for conversationId: String) async throws -> CompactionCheckpointRecord?
    /// Newest checkpoint first.
    func all(for conversationId: String) async throws -> [CompactionCheckpointRecord]
    /// Atomically demote the previous live checkpoint for this conversation and save the new one.
    func save(_ record: CompactionCheckpointRecord) async throws
    /// Delete in one statement; empty IDs are a no-op. Remove checkpoints when
    /// trimming their anchors or future prompts will retain stale summaries.
    func delete(ids: [String]) async throws
}

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

    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await queue.write { db in
            try CompactionCheckpointRecord
                .filter(ids.contains(Column("id")))
                .deleteAll(db)
        }
    }
}
