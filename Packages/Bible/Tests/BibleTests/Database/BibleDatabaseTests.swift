import Testing
@testable import Bible

/// Tests for `BibleDatabase` — the migrations produce the expected
/// reading-position and highlight schema.
@Suite("BibleDatabase")
struct BibleDatabaseTests {
    @Test("v1 creates the reading-position table with its columns")
    func v1CreatesSchema() throws {
        let database = try BibleDatabase.makeInMemory()
        let columns = try database.queue.read { db in
            try db.columns(in: "bibleReadingPosition").map(\.name)
        }
        #expect(
            Set(columns) == ["id", "bookId", "chapterNumber", "translationId", "updatedAt"]
        )
    }

    @Test("v2 creates the highlight table with its columns")
    func v2CreatesHighlightSchema() throws {
        let database = try BibleDatabase.makeInMemory()
        let columns = try database.queue.read { db in
            try db.columns(in: "bibleHighlight").map(\.name)
        }
        #expect(Set(columns) == [
            "id", "bookId", "chapterNumber", "verseNumber",
            "colorId", "createdAt", "updatedAt", "deletedAt",
        ])
    }

    @Test("v2 indexes the highlight table for the chapter query and soft delete")
    func v2CreatesHighlightIndexes() throws {
        let database = try BibleDatabase.makeInMemory()
        let indexes = try database.queue.read { db in
            try db.indexes(on: "bibleHighlight").map(\.name)
        }
        #expect(indexes.contains("bibleHighlight_on_bookId_chapterNumber"))
        #expect(indexes.contains("bibleHighlight_on_deletedAt"))
    }
}
