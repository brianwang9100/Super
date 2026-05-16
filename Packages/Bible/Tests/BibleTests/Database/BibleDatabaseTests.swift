import Foundation
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
            try db.indexes(on: "bibleHighlight")
        }
        let verseIndex = indexes.first { $0.name == "bibleHighlight_on_bookId_chapterNumber_verseNumber" }
        #expect(verseIndex?.isUnique == true, "the verse index enforces one row per verse")
        #expect(indexes.contains { $0.name == "bibleHighlight_on_deletedAt" })
    }

    @Test("v2 rejects a second row for the same verse")
    func v2EnforcesOneRowPerVerse() throws {
        let database = try BibleDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func row(_ id: String) -> BibleHighlightRecord {
            BibleHighlightRecord(
                id: id, bookId: "1PE", chapterNumber: 2, verseNumber: 9,
                colorId: "yellow", createdAt: now, updatedAt: now
            )
        }
        try database.queue.write { db in try row("a").insert(db) }
        #expect(throws: (any Error).self) {
            try database.queue.write { db in try row("b").insert(db) }
        }
    }
}
