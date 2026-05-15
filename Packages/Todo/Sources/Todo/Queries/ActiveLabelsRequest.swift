// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type is
// `AnyPublisher<Value, any Error>`. Conforming a type to it requires the
// `AnyPublisher: Publisher` conformance to be visible in this file — the
// build fails without the import. No Combine data flow is used in our
// code; observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request that observes every non-deleted label, ordered by
/// name (case-insensitive). `@Query(ActiveLabelsRequest())` in a SwiftUI
/// view re-renders automatically when labels change.
public struct ActiveLabelsRequest: ValueObservationQueryable {
    public static var defaultValue: [LabelRecord] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [LabelRecord] {
        try LabelRecord
            .filter(Column("deletedAt") == nil)
            .order(sql: "lower(name) ASC")
            .fetchAll(db)
    }
}
