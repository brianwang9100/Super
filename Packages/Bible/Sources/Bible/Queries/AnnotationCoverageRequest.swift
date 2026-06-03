// `import Combine` is mandatory (see ChapterHighlightsRequest): the
// `ValueObservationQueryable` conformance needs the `AnyPublisher: Publisher`
// conformance visible here. No Combine data flow is used.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing whole-Bible annotation **coverage** — the count
/// of distinct annotated books / chapters / verses backing the hub's
/// `AnnotationCoverageCard`. `@Query` re-renders the card whenever any
/// annotation row is written or cleared, so coverage ticks up live as a bulk
/// run progresses (rows are mutated by the runner, outside the hub view).
public struct AnnotationCoverageRequest: ValueObservationQueryable {
    public static var defaultValue: AnnotationCoverage { .none }

    public init() {}

    public func fetch(_ db: Database) throws -> AnnotationCoverage {
        // Distinct books / chapters, and a verse tally summed over verse-target
        // ranges (`verseEnd - verseStart + 1`). Ranges effectively never overlap
        // for a target, so the sum is the distinct-verse count in practice.
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
