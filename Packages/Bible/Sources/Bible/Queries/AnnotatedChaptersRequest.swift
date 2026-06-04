// `import Combine` is mandatory (see `AnnotationCoverageRequest`): the
// `ValueObservationQueryable` conformance needs the `AnyPublisher: Publisher`
// conformance visible here. No Combine data flow is used.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing which chapters carry **any** annotation — the
/// Generate sheet's per-chapter "Done" badge, and (folded against the catalog by
/// the view model) the per-book badge.
///
/// Returns the set of `(bookId, chapterNumber)` pairs that appear on at least one
/// annotation row with a non-null `chapterNumber` (chapter- and verse-target
/// rows; book-target rows have a nil `chapterNumber` and are excluded). `@Query`
/// re-fires as a bulk run writes rows, so badges light up live.
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
