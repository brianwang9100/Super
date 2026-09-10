// Required for GRDBQuery's AnyPublisher conformance; app data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

public struct ActiveConversationsRequest: ValueObservationQueryable {
    public static var defaultValue: [ConversationRecord] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [ConversationRecord] {
        try ConversationRecord
            .filter(Column("deletedAt") == nil)
            .filter(Column("kind") == ConversationRecord.Kind.user.rawValue)
            .order(Column("updatedAt").desc)
            .fetchAll(db)
    }
}
