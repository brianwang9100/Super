// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type resolves
// to an `AnyPublisher`. Conforming to it needs the `AnyPublisher:
// Publisher` conformance visible here or the build fails. No Combine
// data flow is used — observation runs through GRDB's
// `ValueObservation` and `@Query`. Matches the convention in
// `ChapterAnnotationsRequest`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing every annotation row for one specific
/// target (a book, a chapter, or a single verse range).
///
/// Drives the `AnnotationSheet`'s `@Query` so the popover re-renders
/// whenever a row in this exact group is inserted, replaced, or deleted —
/// including writes from elsewhere (the chapter reader's regenerate path,
/// an in-chat tool call, the future bulk runner).
///
/// Returns rows ordered by `(createdAt ASC, id ASC)`, matching
/// `ChapterAnnotationsRequest` so the card stack inside the sheet
/// preserves the LLM's insertion order.
public struct BibleAnnotationsByTargetRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleAnnotationRecord] { [] }

    public var spec: BibleAnnotationTargetSpec

    public init(spec: BibleAnnotationTargetSpec) {
        self.spec = spec
    }

    public func fetch(_ db: Database) throws -> [BibleAnnotationRecord] {
        var query = BibleAnnotationRecord
            .filter(Column("target") == spec.target.rawValue)
            .filter(Column("bookId") == spec.bookId)

        if let chapterNumber = spec.chapterNumber {
            query = query.filter(Column("chapterNumber") == chapterNumber)
        } else {
            query = query.filter(Column("chapterNumber") == nil)
        }

        if let verseStart = spec.verseStart, let verseEnd = spec.verseEnd {
            query = query
                .filter(Column("verseStart") == verseStart)
                .filter(Column("verseEnd") == verseEnd)
        }

        return try query
            .order(Column("category").asc, Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
    }
}
