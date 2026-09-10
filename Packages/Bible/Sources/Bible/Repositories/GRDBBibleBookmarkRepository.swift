import Core
import Foundation
import GRDB

// Decide, delete, and insert in one transaction to preserve both uniqueness constraints.
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
                try colorRow.delete(db)
                return
            }
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
