// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

/// Reads all slots because the table is bounded at six rows. Ordering is deterministic
/// by book code/chapter, not canonical or display order; consumers impose their own.
public struct AllBookmarksRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleBookmarkRecord] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [BibleBookmarkRecord] {
        try BibleBookmarkRecord
            .order(Column("bookId"), Column("chapterNumber"))
            .fetchAll(db)
    }
}
