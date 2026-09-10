import Foundation
import GRDB

/// Transient dispatcher conversations stay out of the sidebar until hard-deleted.
public struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "conversation"

    public enum Kind: String, Sendable, Codable {
        case user
        case transient
    }

    public var id: String
    public var title: String?
    public var kind: Kind
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String,
        title: String? = nil,
        kind: Kind = .user,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
