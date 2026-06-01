// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves to an
// `AnyPublisher`. Conforming to it needs the `AnyPublisher: Publisher`
// conformance visible here or the build fails. No Combine data flow is used —
// observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing which books carry at least one **book-level**
/// note row.
///
/// Returns the set of `bookId`s with one or more notes whose `target` is
/// `.book` — *not* chapter- or verse-scoped notes. The book picker renders
/// each row's note glyph as filled when its `bookId` is in this set, outline
/// otherwise. Scoping to book-target rows keeps the glyph honest: tapping a
/// filled glyph opens `NotesForRangeRequest(target: .book, …)`, which lists
/// exactly the book-level notes — so the glyph's fill state matches what the
/// tap reveals. (Chapter- and verse-level notes surface on their own glyphs in
/// the reader; a book whose only notes are verse-level shows an *outline* book
/// glyph, whose tap composes a new book-level note.) Using a set keeps
/// row-membership tests O(1) for the picker without per-row queries.
///
/// The `bibleNote_on_target_bookId` index — leading column `target` — lets
/// SQLite seek straight to the `target = 'book'` rows and satisfy the
/// `SELECT DISTINCT bookId` from that slice, per the design's index plan.
public struct BookNotesExistenceRequest: ValueObservationQueryable {
    public static var defaultValue: Set<String> { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> Set<String> {
        let ids = try BibleNoteRecord
            .filter(Column("target") == BibleNoteTarget.book.rawValue)
            .select(Column("bookId"), as: String.self)
            .distinct()
            .fetchAll(db)
        return Set(ids)
    }
}
