import Core
import Foundation
import GRDB

/// GRDB-backed `BibleHighlightRepository` over the `bibleHighlight` table.
///
/// Both writes upsert a single row per `(bookId, chapterNumber, verseNumber)`:
/// `setHighlight` updates an existing row's colour (clearing any `deletedAt`)
/// or inserts a fresh one; `clearHighlight` soft-deletes the active row. New
/// rows get a UUID from the injected `IDGenerator`.
public struct GRDBBibleHighlightRepository: BibleHighlightRepository {
    private let queue: DatabaseQueue
    private let ids: any IDGenerator

    public init(database: BibleDatabase, ids: any IDGenerator = UUIDGenerator()) {
        self.queue = database.queue
        self.ids = ids
    }

    public func setHighlight(
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        color: BibleHighlightColor,
        at now: Date
    ) async throws {
        try await queue.write { db in
            if var existing = try Self.verseRow(
                db, bookId: bookId, chapterNumber: chapterNumber, verseNumber: verseNumber
            ) {
                existing.colorId = color.rawValue
                existing.deletedAt = nil
                existing.updatedAt = now
                try existing.update(db)
            } else {
                try BibleHighlightRecord(
                    id: ids.nextID(),
                    bookId: bookId,
                    chapterNumber: chapterNumber,
                    verseNumber: verseNumber,
                    colorId: color.rawValue,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
        }
    }

    public func clearHighlight(
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        at now: Date
    ) async throws {
        try await queue.write { db in
            guard var record = try Self.verseRow(
                db, bookId: bookId, chapterNumber: chapterNumber, verseNumber: verseNumber
            ), record.deletedAt == nil else { return }
            record.deletedAt = now
            record.updatedAt = now
            try record.update(db)
        }
    }

    public func activeHighlightColors(
        bookId: String,
        chapterNumber: Int,
        verseNumbers: [Int]
    ) async throws -> [Int: BibleHighlightColor] {
        try await queue.read { db in
            let rows = try BibleHighlightRecord
                .filter(Column("bookId") == bookId)
                .filter(Column("chapterNumber") == chapterNumber)
                .filter(verseNumbers.contains(Column("verseNumber")))
                .filter(Column("deletedAt") == nil)
                .fetchAll(db)
            var map: [Int: BibleHighlightColor] = [:]
            for row in rows {
                guard let color = row.color else { continue }
                map[row.verseNumber] = color
            }
            return map
        }
    }

    public func activeHighlights(
        bookId: String,
        chapterNumber: Int
    ) async throws -> [BibleHighlightRecord] {
        try await queue.read { db in
            try BibleHighlightRecord
                .filter(Column("bookId") == bookId)
                .filter(Column("chapterNumber") == chapterNumber)
                .filter(Column("deletedAt") == nil)
                .order(Column("verseNumber"))
                .fetchAll(db)
        }
    }

    public func activeHighlights(
        color: BibleHighlightColor,
        bookId: String?
    ) async throws -> [BibleHighlightRecord] {
        try await queue.read { db in
            var request = BibleHighlightRecord
                .filter(Column("colorId") == color.rawValue)
                .filter(Column("deletedAt") == nil)
            if let bookId {
                request = request.filter(Column("bookId") == bookId)
            }
            return try request
                .order(Column("bookId"), Column("chapterNumber"), Column("verseNumber"))
                .fetchAll(db)
        }
    }

    /// The verse's highlight row regardless of soft-delete state — there is at
    /// most one, so both writes resolve it the same way.
    private static func verseRow(
        _ db: Database,
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int
    ) throws -> BibleHighlightRecord? {
        try BibleHighlightRecord
            .filter(Column("bookId") == bookId)
            .filter(Column("chapterNumber") == chapterNumber)
            .filter(Column("verseNumber") == verseNumber)
            .fetchOne(db)
    }
}
