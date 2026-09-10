import Foundation
import GRDB

public struct GRDBBibleNoteRepository: BibleNoteRepository {
    private let queue: DatabaseQueue

    public init(database: BibleDatabase) {
        self.queue = database.queue
    }

    public func list(
        target: BibleNoteTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> [BibleNoteRecord] {
        try await queue.read { db in
            try Self.targetGroupQuery(
                target: target,
                bookId: bookId,
                chapterNumber: chapterNumber,
                verseStart: verseStart,
                verseEnd: verseEnd
            )
            .order(Column("createdAt").desc, Column("id").asc)
            .fetchAll(db)
        }
    }

    public func insert(_ note: BibleNoteRecord) async throws {
        try await queue.write { db in
            try note.insert(db)
        }
    }

    public func update(id: String, body: String, updatedAt: Date) async throws {
        _ = try await queue.write { db in
            try BibleNoteRecord
                .filter(key: id)
                .updateAll(
                    db,
                    Column("body").set(to: body),
                    Column("updatedAt").set(to: updatedAt)
                )
        }
    }

    public func deleteOne(id: String) async throws {
        _ = try await queue.write { db in
            try BibleNoteRecord.deleteOne(db, key: id)
        }
    }

    // Explicit nil branches produce SQL IS NULL for absent position coordinates.
    private static func targetGroupQuery(
        target: BibleNoteTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) -> QueryInterfaceRequest<BibleNoteRecord> {
        var request = BibleNoteRecord
            .filter(Column("target") == target.rawValue)
            .filter(Column("bookId") == bookId)
        request = applyNullableEquality(request, column: "chapterNumber", value: chapterNumber)
        request = applyNullableEquality(request, column: "verseStart", value: verseStart)
        request = applyNullableEquality(request, column: "verseEnd", value: verseEnd)
        return request
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
