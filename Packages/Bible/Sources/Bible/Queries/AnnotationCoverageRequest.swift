// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

public struct AnnotationCoverageRequest: ValueObservationQueryable {
    public static var defaultValue: AnnotationCoverage { .none }

    public init() {}

    public func fetch(_ db: Database) throws -> AnnotationCoverage {
        // Verse coverage sums inclusive ranges; overlapping ranges would count shared verses more than once.
        let row = try Row.fetchOne(db, sql: """
            SELECT
              COUNT(DISTINCT bookId) AS books,
              COUNT(DISTINCT CASE WHEN chapterNumber IS NOT NULL
                                  THEN bookId || ':' || chapterNumber END) AS chapters,
              COALESCE(SUM(CASE WHEN verseStart IS NOT NULL
                                THEN (verseEnd - verseStart + 1) ELSE 0 END), 0) AS verses
            FROM bibleAnnotation
            """)
        guard let row else { return .none }
        return AnnotationCoverage(
            books: row["books"],
            chapters: row["chapters"],
            verses: row["verses"]
        )
    }
}
