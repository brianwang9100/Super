// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves to an
// `AnyPublisher`. Conforming to it needs the `AnyPublisher: Publisher`
// conformance visible here or the build fails. No Combine data flow is used —
// observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing which books carry a *book-level* annotation
/// row.
///
/// Returns the set of `bookId`s with one or more annotations targeted at the
/// book itself (`target == .book`, i.e. `nil` chapter and verses) — chapter-
/// and verse-level annotations don't count. The book picker renders each
/// row's bubble as filled when its `bookId` is in this set, empty otherwise.
/// Using a set keeps row-membership tests O(1) for the picker without per-row
/// queries.
///
/// The `(target, bookId)` index on `bibleAnnotation` covers this filtered
/// SELECT DISTINCT bookId, so it stays a fast scan.
public struct BookAnnotationsExistenceRequest: ValueObservationQueryable {
    public static var defaultValue: Set<String> { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> Set<String> {
        let ids = try BibleAnnotationRecord
            .filter(Column("target") == BibleAnnotationTarget.book.rawValue)
            .select(Column("bookId"), as: String.self)
            .distinct()
            .fetchAll(db)
        return Set(ids)
    }
}
