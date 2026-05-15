import Foundation
import GRDB

/// Join row between the `task` and `label` tables. The composite primary
/// key (`taskId`, `labelId`) plus per-side `onDelete: .cascade` foreign
/// keys keep the join consistent without an explicit delete pass when a
/// task or label is removed.
///
/// `updatedAt` / `deletedAt` are the sync columns required by
/// `docs/SYNC.md` §6.2; the MVP write path leaves `deletedAt` `nil` and
/// hard-deletes join rows, but the columns ship in v1 so enabling sync
/// later needs no migration.
public struct TaskLabelRecord: Codable, TableRecord, FetchableRecord, PersistableRecord,
                               Sendable, Equatable, Identifiable {
    public static let databaseTableName = "taskLabel"

    public var taskId: String
    public var labelId: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    /// Synthesized identity for the composite-keyed row — `id` is not a
    /// stored column, so GRDB never encodes it.
    public var id: String { "\(taskId)/\(labelId)" }

    public init(
        taskId: String,
        labelId: String,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.taskId = taskId
        self.labelId = labelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
