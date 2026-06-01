// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves to an
// `AnyPublisher`. Conforming to it needs the `AnyPublisher: Publisher`
// conformance visible here or the build fails. No Combine data flow is used —
// observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing every annotation row for one chapter.
///
/// `@Query(constant:)` over this request re-renders the chapter renderer
/// whenever a row in `(bookId, chapterNumber)` is inserted, replaced, or
/// deleted — including writes from outside the reader (the popover's
/// regenerate, the verse-action-modal Annotate tile, an in-chat tool
/// call). The chapter renderer groups results by `verseEnd` to position
/// the trailing bubbles; chapter-target rows (where `verseEnd` is nil)
/// drive the chapter-title bubble.
///
/// Returns rows ordered by `(category ASC, createdAt ASC, id ASC)` so the
/// popover's card stack follows the canonical semantic order
/// (author → summary → historical → clarification → reference) within each
/// verse group, regardless of the order the LLM produced them.
public struct ChapterAnnotationsRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleAnnotationRecord] { [] }

    /// Three-letter book code, e.g. `"ROM"`.
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int

    public init(bookId: String, chapterNumber: Int) {
        self.bookId = bookId
        self.chapterNumber = chapterNumber
    }

    public func fetch(_ db: Database) throws -> [BibleAnnotationRecord] {
        try BibleAnnotationRecord
            .filter(Column("bookId") == bookId)
            // Match chapter-target rows (whose chapterNumber is the
            // chapter) AND verse-target rows in the same chapter. Book
            // -target rows fall out because their `chapterNumber` is nil.
            .filter(Column("chapterNumber") == chapterNumber)
            .order(Column("category").asc, Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
    }
}
