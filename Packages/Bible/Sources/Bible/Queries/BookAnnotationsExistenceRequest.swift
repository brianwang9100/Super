// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

/// Includes only book-level annotations so filled picker glyphs match their target sheets.
public struct BookAnnotationsExistenceRequest: ValueObservationQueryable {
    public static var defaultValue: Set<String> { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> Set<String> {
        let ids = try BibleAnnotationRecord
            .filter(Column("target") == BibleAnnotationTarget.book.rawValue)
            .select(Column("bookId"), as: String.self)
            .distinct()
            .fetchAll(db)
        return Set(ids)
    }
}
