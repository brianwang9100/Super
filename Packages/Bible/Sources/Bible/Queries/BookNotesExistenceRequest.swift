// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves to an
// `AnyPublisher`. Conforming to it needs the `AnyPublisher: Publisher`
// conformance visible here or the build fails. No Combine data flow is used —
// observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing which books carry at least one note row.
///
/// Returns the set of `bookId`s with one or more notes at *any* target level —
/// book, chapter, or verse. The book picker renders each row's note glyph as
/// filled when its `bookId` is in this set, outline otherwise. Using a set
/// keeps row-membership tests O(1) for the picker without per-row queries.
///
/// The `bibleNote_on_bookId_chapterNumber_verseEnd` index — whose leading
/// column is `bookId` — lets SQLite satisfy this `SELECT DISTINCT bookId`
/// with an index scan rather than a full table scan. (The `(target, bookId)`
/// index does not help here: its leading column is `target`, and there is no
/// `target` filter to seek on.)
public struct BookNotesExistenceRequest: ValueObservationQueryable {
    public static var defaultValue: Set<String> { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> Set<String> {
        let ids = try BibleNoteRecord
            .select(Column("bookId"), as: String.self)
            .distinct()
            .fetchAll(db)
        return Set(ids)
    }
}
