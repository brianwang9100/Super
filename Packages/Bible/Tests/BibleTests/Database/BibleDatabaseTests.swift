import Testing
@testable import Bible

/// Tests for `BibleDatabase` — the v1 migration produces the expected
/// reading-position schema.
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
}
