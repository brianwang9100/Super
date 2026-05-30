import Foundation
import GRDB

/// One Chat conversation. `title` is auto-generated from the first user
/// message and editable from the sidebar; `deletedAt` is the soft-delete
/// tombstone retained until sync confirms server acknowledgement (per
/// `docs/SYNC.md`), then hard-deleted.
///
/// `kind` discriminates user-visible conversations (the default,
/// `"user"`) from transient ones created by the headless
/// `bible.annotate` dispatcher (`"transient"`). The Chats list filters
/// out non-`"user"` kinds; the dispatcher hard-deletes transient rows
/// when its turn ends, so the discriminator exists only as a guard
/// against in-flight transient sessions leaking into the sidebar.
public struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "conversation"

    /// User-facing or system-internal discriminator. Pre-v5 rows
    /// backfill to `.user`.
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
