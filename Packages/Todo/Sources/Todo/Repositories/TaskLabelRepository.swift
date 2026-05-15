import Foundation
import GRDB

/// Persistence boundary for the task↔label join table. Bulk lookup is the
/// hot path: the screen loads one task list, then asks for every label
/// row on every task at once.
public protocol TaskLabelRepository: Sendable {
    /// All non-deleted labels attached to `taskId`, ordered by name
    /// (case-insensitive).
    func labels(forTaskId taskId: String) async throws -> [LabelRecord]
    /// Bulk lookup keyed by task id. Returns one entry per task that has
    /// at least one non-deleted label; a missing key means "no labels".
    func labels(forTaskIds taskIds: [String]) async throws -> [String: [LabelRecord]]
    /// Replace the full set of labels for `taskId`: inserts join rows for
    /// ids not yet present, deletes rows no longer in `labelIds`. Atomic.
    func setLabels(taskId: String, labelIds: [String], at timestamp: Date) async throws
}

/// GRDB-backed `TaskLabelRepository`.
///
/// `labels(forTaskIds:)` runs two queries (join rows, then the labels they
/// reference) and groups in Swift, rather than a single SQL join. This
/// keeps decoding to GRDB's plain synthesized `FetchableRecord` path and
/// sidesteps the fragility of nested-column-alias decoding.
public struct GRDBTaskLabelRepository: TaskLabelRepository {
    private let queue: DatabaseQueue

    public init(database: TodoDatabase) {
        self.queue = database.queue
    }

    public func labels(forTaskId taskId: String) async throws -> [LabelRecord] {
        try await labels(forTaskIds: [taskId])[taskId] ?? []
    }

    public func labels(forTaskIds taskIds: [String]) async throws -> [String: [LabelRecord]] {
        guard !taskIds.isEmpty else { return [:] }
        return try await queue.read { db in
            let joinRows = try TaskLabelRecord
                .filter(taskIds.contains(Column("taskId")))
                .filter(Column("deletedAt") == nil)
                .fetchAll(db)
            let labelIds = Array(Set(joinRows.map(\.labelId)))
            guard !labelIds.isEmpty else { return [:] }
            let labelRows = try LabelRecord
                .filter(labelIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .fetchAll(db)
            let lookup = Dictionary(uniqueKeysWithValues: labelRows.map { ($0.id, $0) })

            var result: [String: [LabelRecord]] = [:]
            for join in joinRows {
                guard let label = lookup[join.labelId] else { continue }
                result[join.taskId, default: []].append(label)
            }
            for key in result.keys {
                result[key]?.sort { $0.name.lowercased() < $1.name.lowercased() }
            }
            return result
        }
    }

    public func setLabels(taskId: String, labelIds: [String], at timestamp: Date) async throws {
        try await queue.write { db in
            let desired = Set(labelIds)
            let existingIds = Set(
                try TaskLabelRecord
                    .filter(Column("taskId") == taskId)
                    .filter(Column("deletedAt") == nil)
                    .fetchAll(db)
                    .map(\.labelId)
            )
            for labelId in desired.subtracting(existingIds) {
                try TaskLabelRecord(
                    taskId: taskId, labelId: labelId,
                    createdAt: timestamp, updatedAt: timestamp
                ).save(db)
            }
            let toDelete = existingIds.subtracting(desired)
            if !toDelete.isEmpty {
                _ = try TaskLabelRecord
                    .filter(Column("taskId") == taskId)
                    .filter(Array(toDelete).contains(Column("labelId")))
                    .deleteAll(db)
            }
        }
    }
}
