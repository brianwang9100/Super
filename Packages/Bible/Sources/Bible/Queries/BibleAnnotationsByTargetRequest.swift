// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

/// Observes one exact target group, ordered by createdAt ASC then id ASC.
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
            .order(Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
    }
}
