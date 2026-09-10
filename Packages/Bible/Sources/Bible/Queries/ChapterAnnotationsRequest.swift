// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

/// Includes chapter and verse targets. verseEnd anchors range bubbles; nil anchors
/// the chapter-title bubble. Ordering is stable by createdAt ASC, id ASC.
public struct ChapterAnnotationsRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleAnnotationRecord] { [] }

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
            .filter(Column("chapterNumber") == chapterNumber)
            .order(Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
    }
}
