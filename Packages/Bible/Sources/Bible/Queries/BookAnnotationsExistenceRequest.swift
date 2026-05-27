import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing which books carry at least one annotation
/// row.
///
/// Returns the set of `bookId`s with one or more annotations at *any*
/// target level — book, chapter, or verse. The book picker renders each
/// row's bubble as filled when its `bookId` is in this set, empty
/// otherwise. Using a set keeps row-membership tests O(1) for the picker
/// without per-row queries.
///
/// The two indexes on `bibleAnnotation` make this a fast scan: the
/// `(target, bookId)` index covers a SELECT DISTINCT bookId, and the
/// chapter-positioning index doesn't need to be touched.
public struct BookAnnotationsExistenceRequest: ValueObservationQueryable {
    public static var defaultValue: Set<String> { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> Set<String> {
        let ids = try String.fetchAll(
            db,
            sql: "SELECT DISTINCT bookId FROM bibleAnnotation"
        )
        return Set(ids)
    }
}
