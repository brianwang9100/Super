import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request observing every note in one exact target group.
///
/// Backs the `NoteListSheet` so a note written from outside the open sheet —
/// an in-chat `bible.note` call — appears live without a manual reload. The
/// range key is the full `(target, bookId, chapterNumber?, verseStart?,
/// verseEnd?)` tuple; nullable position columns are matched with explicit
/// IS-NULL branches because GRDB's `nil`-typed comparisons always evaluate
/// false in SQL.
///
/// Returns rows ordered `(createdAt DESC, id ASC)` — newest note on top.
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
