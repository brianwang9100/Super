import Foundation
import GRDB

/// One Chat conversation. `title` is auto-generated from the first user
/// message and editable from the sidebar; `deletedAt` is the soft-delete
/// tombstone retained until sync confirms server acknowledgement (per
/// `docs/SYNC.md`), then hard-deleted.
public struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "conversation"

    public var id: String
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String,
        title: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
