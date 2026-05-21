// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves
// to an `AnyPublisher`. Conforming to it needs the
// `AnyPublisher: Publisher` conformance visible here or the build fails.
// No Combine data flow is used — observation runs through GRDB's
// `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing every memory in the Chat database,
/// oldest first.
///
/// `@Query(constant:)` over this request re-renders `SettingsMemoryPane`
/// whenever the LLM (Large Language Model) writes via the `memory` tool
/// or the user mutates from the pane — both flow through the same
/// `memory` table, so the user always sees the live set.
public struct MemoriesRequest: ValueObservationQueryable {
    public static var defaultValue: [MemoryRecord] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [MemoryRecord] {
        try MemoryRecord
            .order(Column("createdAt"))
            .fetchAll(db)
    }
}
