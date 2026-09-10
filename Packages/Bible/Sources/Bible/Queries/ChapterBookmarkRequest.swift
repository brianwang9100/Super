// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

/// The reader is recreated per chapter so @Query(constant:) keeps valid parameters.
public struct ChapterBookmarkRequest: ValueObservationQueryable {
    public static var defaultValue: BibleBookmarkRecord? { nil }

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
