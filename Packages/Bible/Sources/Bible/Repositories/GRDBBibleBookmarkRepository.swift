import Core
import Foundation
import GRDB

/// GRDB-backed `BibleBookmarkRepository` over the `bibleBookmark` table.
///
/// `toggle` runs all of its decision inside one `DatabaseQueue.write` — a
/// single transaction — so the delete-then-insert sequence that implements
/// "move" and "replace" can never violate the table's two UNIQUE indexes
/// mid-flight. New rows get a UUID from the injected `IDGenerator`.
public struct GRDBBibleBookmarkRepository: BibleBookmarkRepository {
    private let queue: DatabaseQueue
    private let ids: any IDGenerator

    public init(database: BibleDatabase, ids: any IDGenerator = UUIDGenerator()) {
        self.queue = database.queue
        self.ids = ids
    }

    public func toggle(
        color: BibleBookmarkColor,
        bookId: String,
        chapterNumber: Int,
        at now: Date
    ) async throws {
        try await queue.write { db in
            let colorRow = try BibleBookmarkRecord
                .filter(Column("colorId") == color.rawValue)
                .fetchOne(db)
            if let colorRow, colorRow.bookId == bookId, colorRow.chapterNumber == chapterNumber {
                // The chapter's own ribbon — toggle it off.
                try colorRow.delete(db)
                return
            }
            // Free the colour's previous chapter (move) and the chapter's
            // previous colour (replace), then land the new assignment.
            try colorRow?.delete(db)
            try BibleBookmarkRecord
                .filter(Column("bookId") == bookId)
                .filter(Column("chapterNumber") == chapterNumber)
                .deleteAll(db)
            try BibleBookmarkRecord(
                id: ids.nextID(),
                colorId: color.rawValue,
                bookId: bookId,
                chapterNumber: chapterNumber,
                createdAt: now
            ).insert(db)
        }
    }

    public func allBookmarks() async throws -> [BibleBookmarkRecord] {
        try await queue.read { db in
            try AllBookmarksRequest().fetch(db)
        }
    }
}
