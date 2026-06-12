// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves to an
// `AnyPublisher`. Conforming to it needs the `AnyPublisher: Publisher`
// conformance visible here or the build fails. No Combine data flow is used —
// observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing every assigned bookmark slot.
///
/// One whole-table request deliberately serves the multi-chapter surfaces —
/// the bookmark sheet's card grid, the book picker's row/cell indicators,
/// and the Bookmarks applet's slot list — because the table is bounded at
/// six rows (one per `BibleBookmarkColor`), so per-surface filtering buys
/// nothing there. The chapter reader is the one exception: it keeps the
/// package's per-chapter constant-request convention via
/// `ChapterBookmarkRequest`, beside its highlight/annotation/note requests.
///
/// The `(bookId, chapterNumber)` ordering is for **determinism only** — raw
/// three-letter codes sort neither in canonical scripture order nor
/// alphabetically by book name. Every consumer imposes its own display
/// order: the sheet grid and slot list iterate `BibleBookmarkColor.allCases`,
/// the book picker groups by its catalog's book order.
public struct AllBookmarksRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleBookmarkRecord] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [BibleBookmarkRecord] {
        try BibleBookmarkRecord
            .order(Column("bookId"), Column("chapterNumber"))
            .fetchAll(db)
    }
}
