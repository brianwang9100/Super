import Foundation
import GRDB
import Testing
@testable import Bible

/// Fetch tests for the two bookmark GRDBQuery requests — the whole-table
/// `AllBookmarksRequest` (sheet grid, book picker, Bookmarks screen) and the
/// per-chapter `ChapterBookmarkRequest` (reader title glyph).
@Suite("Bookmark queries")
struct BookmarkQueriesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func seed(_ database: BibleDatabase, _ rows: [(String, String, Int)]) throws {
        try database.queue.write { db in
            for (color, bookId, chapter) in rows {
                try BibleBookmarkRecord(
                    id: "bm-\(color)", colorId: color, bookId: bookId,
                    chapterNumber: chapter, createdAt: now
                ).insert(db)
            }
        }
    }

    // `defaultValue` is MainActor-isolated by `ValueObservationQueryable`,
    // so the two tests asserting it run on the main actor.
    @Test("AllBookmarksRequest defaults to empty and fetches every row ordered")
    @MainActor
    func allBookmarksFetchesOrdered() throws {
        #expect(AllBookmarksRequest.defaultValue.isEmpty)
        let database = try BibleDatabase.makeInMemory()
        try seed(database, [("plum", "ROM", 8), ("clay", "JHN", 3), ("gold", "JHN", 1)])
        let rows = try database.queue.read { db in
            try AllBookmarksRequest().fetch(db)
        }
        #expect(rows.map(\.colorId) == ["gold", "clay", "plum"])
    }

    @Test("ChapterBookmarkRequest finds the chapter's bookmark")
    func chapterBookmarkFindsRow() throws {
        let database = try BibleDatabase.makeInMemory()
        try seed(database, [("clay", "JHN", 3)])
        let row = try database.queue.read { db in
            try ChapterBookmarkRequest(bookId: "JHN", chapterNumber: 3).fetch(db)
        }
        #expect(row?.color == .clay)
    }

    @Test("ChapterBookmarkRequest is nil for an unbookmarked chapter")
    @MainActor
    func chapterBookmarkNilWhenAbsent() throws {
        #expect(ChapterBookmarkRequest.defaultValue == nil)
        let database = try BibleDatabase.makeInMemory()
        try seed(database, [("clay", "JHN", 3)])
        let row = try database.queue.read { db in
            try ChapterBookmarkRequest(bookId: "JHN", chapterNumber: 4).fetch(db)
        }
        #expect(row == nil)
    }
}
