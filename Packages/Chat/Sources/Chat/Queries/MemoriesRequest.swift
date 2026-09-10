// Required for GRDBQuery's AnyPublisher conformance; app data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

public struct MemoriesRequest: ValueObservationQueryable {
    public static var defaultValue: [MemoryRecord] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [MemoryRecord] {
        try MemoryRecord
            .order(Column("createdAt"))
            .fetchAll(db)
    }
}
