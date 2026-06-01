import Foundation
import GRDB

/// GRDB-backed `BibleAnnotationRepository` over the `bibleAnnotation` table.
///
/// `replace(...)` runs the delete and the inserts in one `queue.write`
/// transaction so a regenerate that throws mid-call leaves the existing
/// rows intact. Throws originating below the transaction roll back
/// automatically — there is no partial-state window where the popover
/// could observe the old rows gone but the new rows not yet inserted.
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
            .order(Column("category").asc, Column("createdAt").asc, Column("id").asc)
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
            // Belt-and-braces: a caller passing records whose position
            // fields disagree with the target-group arguments would land
            // hidden in the table, untouched by a later replace on the
            // same group. Reject explicitly so the inconsistency surfaces.
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

    public func deleteOne(id: String) async throws {
        _ = try await queue.write { db in
            try BibleAnnotationRecord.deleteOne(db, key: id)
        }
    }

    /// The base query for one target group. Equality on a nullable column
    /// in GRDB needs the IS-NULL branch explicit; `nil`-typed comparisons
    /// otherwise compile but always evaluate false in SQL.
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

/// Errors thrown by `GRDBBibleAnnotationRepository` for caller-side mistakes.
public enum BibleAnnotationRepositoryError: Error, Sendable, Equatable {
    /// A record passed to `replace(...)` carries position fields that
    /// don't match the target-group arguments — the row would be
    /// orphaned from the group it claims to belong to.
    case recordOutsideTargetGroup(id: String)
}
