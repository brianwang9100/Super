// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

/// Includes chapter and verse targets. verseEnd anchors range glyphs; nil anchors
/// the title glyph. Newest-first ordering matches the list sheet.
public struct ChapterNotesRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleNoteRecord] { [] }

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
            .filter(Column("chapterNumber") == chapterNumber)
            .order(Column("createdAt").desc, Column("id").asc)
            .fetchAll(db)
    }
}
