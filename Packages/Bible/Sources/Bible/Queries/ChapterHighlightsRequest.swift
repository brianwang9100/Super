// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves to an
// `AnyPublisher`. Conforming to it needs the `AnyPublisher: Publisher`
// conformance visible here or the build fails. No Combine data flow is used —
// observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing one chapter's active verse highlights.
///
/// `@Query(constant:)` over this request re-renders the chapter whenever a
/// highlight in `(bookId, chapterNumber)` is written or cleared — including a
/// write from outside the reader (a future highlights list, or a sync-restored
/// database). The chapter renderer is recreated per position, so the request's
/// parameters are fixed for the life of each `@Query`.
public struct ChapterHighlightsRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleHighlightRecord] { [] }

    /// Three-letter book code, e.g. `"1PE"`.
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int

    public init(bookId: String, chapterNumber: Int) {
        self.bookId = bookId
        self.chapterNumber = chapterNumber
    }

    public func fetch(_ db: Database) throws -> [BibleHighlightRecord] {
        try BibleHighlightRecord
            .filter(Column("bookId") == bookId)
            .filter(Column("chapterNumber") == chapterNumber)
            .filter(Column("deletedAt") == nil)
            .order(Column("verseNumber"))
            .fetchAll(db)
    }
}
