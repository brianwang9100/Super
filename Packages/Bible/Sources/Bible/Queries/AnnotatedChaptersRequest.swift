// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

/// Includes chapter and verse annotations; book-level rows have no chapter and are excluded.
public struct AnnotatedChaptersRequest: ValueObservationQueryable {
    public static var defaultValue: Set<ChapterRef> { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> Set<ChapterRef> {
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT bookId, chapterNumber
            FROM bibleAnnotation
            WHERE chapterNumber IS NOT NULL
            """)
        return Set(rows.map { ChapterRef(bookID: $0["bookId"], number: $0["chapterNumber"]) })
    }
}
