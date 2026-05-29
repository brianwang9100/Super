import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing which books carry at least one note row.
///
/// Returns the set of `bookId`s with one or more notes at *any* target level —
/// book, chapter, or verse. The book picker renders each row's note glyph as
/// filled when its `bookId` is in this set, outline otherwise. Using a set
/// keeps row-membership tests O(1) for the picker without per-row queries.
///
/// The `(target, bookId)` index makes this a fast SELECT DISTINCT bookId.
public struct BookNotesExistenceRequest: ValueObservationQueryable {
    public static var defaultValue: Set<String> { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> Set<String> {
        let ids = try BibleNoteRecord
            .select(Column("bookId"), as: String.self)
            .distinct()
            .fetchAll(db)
        return Set(ids)
    }
}
