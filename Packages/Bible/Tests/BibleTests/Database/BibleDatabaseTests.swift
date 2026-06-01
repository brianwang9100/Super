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

    @Test("the annotation table carries a category column (kind dropped by v5)")
    func annotationSchemaHasCategory() throws {
        let database = try BibleDatabase.makeInMemory()
        let columns = try database.queue.read { db in
            try db.columns(in: "bibleAnnotation").map(\.name)
        }
        #expect(Set(columns) == [
            "id", "target", "bookId", "chapterNumber",
            "verseStart", "verseEnd", "category", "title",
            "body", "source", "modelId", "createdAt",
        ])
        #expect(!columns.contains("kind"), "v5 replaced the kind column with category")
    }

    @Test("v5 rebuilds the annotation table with category typed as INTEGER")
    func v5CategoryIsInteger() throws {
        let database = try BibleDatabase.makeInMemory()
        let categoryColumn = try database.queue.read { db in
            try db.columns(in: "bibleAnnotation").first { $0.name == "category" }
        }
        #expect(categoryColumn?.isNotNull == true)
        // Int-backed enum persists as INTEGER so `ORDER BY category` is a
        // plain integer sort.
        #expect(categoryColumn?.type.uppercased() == "INTEGER")
    }

    @Test("v5 CHECK rejects a category outside the 1...5 range")
    func v5CategoryCheckConstraint() throws {
        let database = try BibleDatabase.makeInMemory()
        // Raw inserts bypass the Swift enum, which is the only way an
        // out-of-range value could reach the column. A valid category
        // inserts; an out-of-range one is rejected at write time by the
        // CHECK rather than corrupting the read path.
        func insert(category: Int) throws {
            try database.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO bibleAnnotation
                    (id, target, bookId, category, title, body, source, modelId, createdAt)
                    VALUES (?, 'book', 'ROM', ?, 't', 'b', 'user', 'm', '2026-01-01 00:00:00.000')
                    """,
                    arguments: ["row-\(category)", category]
                )
            }
        }
        try insert(category: 5)                       // in range — succeeds
        #expect(throws: (any Error).self) {
            try insert(category: 6)                    // out of range — rejected
        }
        #expect(throws: (any Error).self) {
            try insert(category: 0)
        }
    }

    @Test("an out-of-range category that reaches a row fails the read closed, not corrupt")
    func outOfRangeCategoryFailsClosedOnRead() throws {
        let database = try BibleDatabase.makeInMemory()
        // The v5 CHECK makes this unreachable from the app's own writes, so
        // bypass it to simulate a value arriving another way (a future sync
        // payload, a manual DB edit). The enum's synthesized decoder rejects
        // the unknown raw value, so the whole fetch throws rather than
        // surfacing a half-decoded row — in the live app this is what makes
        // `@Query` fall back to `defaultValue: []` (cards blank closed) rather
        // than crash or render corrupt data.
        try database.queue.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(
                sql: """
                INSERT INTO bibleAnnotation
                (id, target, bookId, category, title, body, source, modelId, createdAt)
                VALUES ('bad', 'book', 'ROM', 99, 't', 'b', 'user', 'm', '2026-01-01 00:00:00.000')
                """
            )
        }
        #expect(throws: (any Error).self) {
            try database.queue.read { db in
                try BibleAnnotationRecord.fetchAll(db)
            }
        }
    }

    @Test("v3 indexes the annotation table for chapter and book lookups")
    func v3CreatesAnnotationIndexes() throws {
        let database = try BibleDatabase.makeInMemory()
        let indexes = try database.queue.read { db in
            try db.indexes(on: "bibleAnnotation")
        }
        // The chapter-positioning index drives the reader's `@Query` and
        // groups bubbles by `verseEnd`. The target+book index drives the
        // book-picker's `BookAnnotationsExistenceRequest`. Neither is
        // UNIQUE — the table allows multiple rows per target group, with
        // ordering enforced by `(category, createdAt, id)` rather than the
        // schema.
        #expect(indexes.contains {
            $0.name == "bibleAnnotation_on_bookId_chapterNumber_verseEnd"
                && $0.isUnique == false
        })
        #expect(indexes.contains {
            $0.name == "bibleAnnotation_on_target_bookId"
                && $0.isUnique == false
        })
    }
}
