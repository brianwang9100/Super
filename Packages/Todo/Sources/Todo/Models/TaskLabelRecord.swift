import Foundation
import GRDB

/// Join row between the `task` and `label` tables. The composite primary
/// key (`taskId`, `labelId`) plus per-side `onDelete: .cascade` foreign
/// keys keep the join consistent without an explicit delete pass when a
/// task or label is removed.
public struct TaskLabelRecord: Codable, TableRecord, FetchableRecord, PersistableRecord,
                               Sendable, Equatable, Identifiable {
    public static let databaseTableName = "taskLabel"

    public var taskId: String
    public var labelId: String
    public var createdAt: Date

    /// Synthesized identity for the composite-keyed row — `id` is not a
    /// stored column, so GRDB never encodes it.
    public var id: String { "\(taskId)/\(labelId)" }

    public init(taskId: String, labelId: String, createdAt: Date) {
        self.taskId = taskId
        self.labelId = labelId
        self.createdAt = createdAt
    }
}
