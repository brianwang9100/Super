import Foundation
import GRDB

// One write transaction preserves old rows if replacement throws and prevents partial query results.
public struct GRDBBibleAnnotationRepository: BibleAnnotationRepository {
    private let queue: DatabaseQueue

    public init(database: BibleDatabase) {
        self.queue = database.queue
    }

    public func list(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> [BibleAnnotationRecord] {
        try await queue.read { db in
            try Self.targetGroupQuery(
                target: target,
                bookId: bookId,
                chapterNumber: chapterNumber,
                verseStart: verseStart,
                verseEnd: verseEnd
            )
            .order(Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
        }
    }

    public func replace(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?,
        inserting records: [BibleAnnotationRecord]
    ) async throws {
        try await queue.write { db in
            // Reject mismatched positions or future replacements would leave these rows outside their group.
            for record in records {
                guard record.target == target,
                      record.bookId == bookId,
                      record.chapterNumber == chapterNumber,
                      record.verseStart == verseStart,
                      record.verseEnd == verseEnd
                else {
                    throw BibleAnnotationRepositoryError.recordOutsideTargetGroup(id: record.id)
                }
            }
            try Self.targetGroupQuery(
                target: target,
                bookId: bookId,
                chapterNumber: chapterNumber,
                verseStart: verseStart,
                verseEnd: verseEnd
            )
            .deleteAll(db)
            for record in records {
                try record.insert(db)
            }
        }
    }

    public func hasAnnotation(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> Bool {
        try await queue.read { db in
            try Self.targetGroupQuery(
                target: target,
                bookId: bookId,
                chapterNumber: chapterNumber,
                verseStart: verseStart,
                verseEnd: verseEnd
            )
            .isEmpty(db) == false
        }
    }

    public func hasVerseAnnotations(bookId: String, chapterNumber: Int) async throws -> Bool {
        try await queue.read { db in
            try BibleAnnotationRecord
                .filter(Column("target") == BibleAnnotationTarget.verse.rawValue)
                .filter(Column("bookId") == bookId)
                .filter(Column("chapterNumber") == chapterNumber)
                .isEmpty(db) == false
        }
    }

    public func deleteOne(id: String) async throws {
        _ = try await queue.write { db in
            try BibleAnnotationRecord.deleteOne(db, key: id)
        }
    }

    public func deleteAll() async throws {
        _ = try await queue.write { db in
            try BibleAnnotationRecord.deleteAll(db)
        }
    }

    // Explicit nil branches produce SQL IS NULL for absent position coordinates.
    private static func targetGroupQuery(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) -> QueryInterfaceRequest<BibleAnnotationRecord> {
        var request = BibleAnnotationRecord
            .filter(Column("target") == target.rawValue)
            .filter(Column("bookId") == bookId)
        request = applyNullableEquality(request, column: "chapterNumber", value: chapterNumber)
        request = applyNullableEquality(request, column: "verseStart", value: verseStart)
        request = applyNullableEquality(request, column: "verseEnd", value: verseEnd)
        return request
    }

    private static func applyNullableEquality(
        _ request: QueryInterfaceRequest<BibleAnnotationRecord>,
        column name: String,
        value: Int?
    ) -> QueryInterfaceRequest<BibleAnnotationRecord> {
        if let value {
            return request.filter(Column(name) == value)
        } else {
            return request.filter(Column(name) == nil)
        }
    }
}

public enum BibleAnnotationRepositoryError: Error, Sendable, Equatable {
    /// A replacement row's positions disagree with its target group.
    case recordOutsideTargetGroup(id: String)
}
