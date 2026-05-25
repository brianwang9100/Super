// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves
// to an `AnyPublisher`. Conforming to it needs the
// `AnyPublisher: Publisher` conformance visible here or the build fails.
// No Combine data flow is used — observation runs through GRDB's
// `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing every non-deleted conversation in the
/// Chat database, ordered newest-update-first.
///
/// `@Query(ActiveConversationsRequest())` over this request re-renders
/// the Chats applet's list whenever a write touches the `conversation`
/// table — a new chat created from the overlay, a row's `updatedAt`
/// bumped by a message send, or a soft-delete from a future long-press
/// menu — without any manual refresh wiring.
public struct ActiveConversationsRequest: ValueObservationQueryable {
    public static var defaultValue: [ConversationRecord] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [ConversationRecord] {
        try ConversationRecord
            .filter(Column("deletedAt") == nil)
            .order(Column("updatedAt").desc)
            .fetchAll(db)
    }
}
