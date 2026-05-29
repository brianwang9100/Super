// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves to an
// `AnyPublisher`. Conforming to it needs the `AnyPublisher: Publisher`
// conformance visible here or the build fails. No Combine data flow is used —
// observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing every note row for one chapter.
///
/// `@Query(constant:)` over this request re-renders the chapter renderer
/// whenever a row in `(bookId, chapterNumber)` is inserted, edited, or
/// deleted — including writes from outside the reader (the note editor, an
/// in-chat `bible.note` tool call). The renderer groups results by `verseEnd`
/// to position the trailing note glyphs; chapter-target rows (where `verseEnd`
/// is nil) drive the chapter-title glyph.
///
/// Returns rows ordered by `(createdAt DESC, id ASC)` to match the list
/// sheet's newest-first card order.
public struct ChapterNotesRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleNoteRecord] { [] }

    /// Three-letter book code, e.g. `"JHN"`.
    public var bookId: String
    /// 1-based chapter number.
    public var chapterNumber: Int

    public init(bookId: String, chapterNumber: Int) {
        self.bookId = bookId
        self.chapterNumber = chapterNumber
    }

    public func fetch(_ db: Database) throws -> [BibleNoteRecord] {
        try BibleNoteRecord
            .filter(Column("bookId") == bookId)
            // Match chapter-target rows (whose chapterNumber is this chapter)
            // AND verse-target rows in the same chapter. Book-target rows fall
            // out because their `chapterNumber` is nil.
            .filter(Column("chapterNumber") == chapterNumber)
            .order(Column("createdAt").desc, Column("id").asc)
            .fetchAll(db)
    }
}
