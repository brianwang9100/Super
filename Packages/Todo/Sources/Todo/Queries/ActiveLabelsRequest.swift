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
