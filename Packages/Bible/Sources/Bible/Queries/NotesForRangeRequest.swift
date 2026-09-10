// Required for GRDBQuery's AnyPublisher conformance; data flow still uses @Query.
import Combine
import GRDB
import GRDBQuery

/// Observes the exact target and nullable position tuple, newest first.
/// Use explicit nil branches so empty coordinates compare as SQL IS NULL.
public struct NotesForRangeRequest: ValueObservationQueryable {
    public static var defaultValue: [BibleNoteRecord] { [] }

    public var target: BibleNoteTarget
    public var bookId: String
    public var chapterNumber: Int?
    public var verseStart: Int?
    public var verseEnd: Int?

    public init(
        target: BibleNoteTarget,
        bookId: String,
        chapterNumber: Int? = nil,
        verseStart: Int? = nil,
        verseEnd: Int? = nil
    ) {
        self.target = target
        self.bookId = bookId
        self.chapterNumber = chapterNumber
        self.verseStart = verseStart
        self.verseEnd = verseEnd
    }

    public func fetch(_ db: Database) throws -> [BibleNoteRecord] {
        var request = BibleNoteRecord
            .filter(Column("target") == target.rawValue)
            .filter(Column("bookId") == bookId)
        request = Self.applyNullableEquality(request, column: "chapterNumber", value: chapterNumber)
        request = Self.applyNullableEquality(request, column: "verseStart", value: verseStart)
        request = Self.applyNullableEquality(request, column: "verseEnd", value: verseEnd)
        return try request
            .order(Column("createdAt").desc, Column("id").asc)
            .fetchAll(db)
    }

    private static func applyNullableEquality(
        _ request: QueryInterfaceRequest<BibleNoteRecord>,
        column name: String,
        value: Int?
    ) -> QueryInterfaceRequest<BibleNoteRecord> {
        if let value {
            return request.filter(Column(name) == value)
        } else {
            return request.filter(Column(name) == nil)
        }
    }
}
