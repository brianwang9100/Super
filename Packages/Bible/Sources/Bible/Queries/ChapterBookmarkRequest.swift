// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves to an
// `AnyPublisher`. Conforming to it needs the `AnyPublisher: Publisher`
// conformance visible here or the build fails. No Combine data flow is used —
// observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing one chapter's bookmark slot, if any.
///
/// `@Query(constant:)` over this request fills or empties the reader's
/// chapter-title bookmark glyph whenever the chapter's ribbon changes —
/// including a write from outside the reader (the bookmark sheet *moving* a
/// ribbon here from another chapter, or the Bookmarks applet). The chapter
/// renderer is recreated per position, so the request's parameters are fixed
/// for the life of each `@Query`.
public struct ChapterBookmarkRequest: ValueObservationQueryable {
    public static var defaultValue: BibleBookmarkRecord? { nil }

    /// Three-letter book code, e.g. `"JHN"`.
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int

    public init(bookId: String, chapterNumber: Int) {
        self.bookId = bookId
        self.chapterNumber = chapterNumber
    }

    public func fetch(_ db: Database) throws -> BibleBookmarkRecord? {
        try BibleBookmarkRecord
            .filter(Column("bookId") == bookId)
            .filter(Column("chapterNumber") == chapterNumber)
            .fetchOne(db)
    }
}
