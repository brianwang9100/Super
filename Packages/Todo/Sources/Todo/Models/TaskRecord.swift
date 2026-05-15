import Foundation
import GRDB

/// One todo task. `sortOrder` is a REAL so a future manual-reorder UX can
/// insert a row between two adjacent rows without rewriting every index.
/// `deletedAt` is the soft-delete tombstone retained until sync confirms
/// the server acknowledges the delete (per `docs/SYNC.md`); the MVP only
/// surfaces rows where it is `nil`.
public struct TaskRecord: Codable, TableRecord, FetchableRecord, PersistableRecord,
                          Sendable, Equatable, Identifiable {
    public static let databaseTableName = "task"

    public var id: String
    public var title: String
    public var notes: String
    public var priority: TaskPriority
    public var state: TaskState
    public var dueAt: Date?
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String,
        title: String,
        notes: String = "",
        priority: TaskPriority = .normal,
        state: TaskState = .open,
        dueAt: Date? = nil,
        sortOrder: Double,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.priority = priority
        self.state = state
        self.dueAt = dueAt
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
