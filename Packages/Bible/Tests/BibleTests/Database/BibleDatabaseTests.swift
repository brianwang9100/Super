import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests highlight uniqueness and the seeded legacy annotation upgrade.
/// `BibleSchemaSnapshotTests` owns the complete current schema inventory.
@Suite("BibleDatabase")
struct BibleDatabaseTests {
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

    /// The legacy → v9 upgrade path: a database stopped at v8 carries the
    /// multi-card `(category, title, body)` annotation shape; running the
    /// full migrator must drop those rows wholesale (destructive by
    /// design — there is no mapping onto the single-summary model),
    /// rebuild the table with `summary`, and recreate both indexes.
    @Test("v9 drops legacy multi-card rows and rebuilds the summary schema")
    func v9MigratesLegacyAnnotationTable() throws {
        let queue = try DatabaseQueue()
        // A release-shaped migrator (no DEBUG erase-on-change) so the test
        // exercises the real upgrade an existing install performs.
        var migrator = DatabaseMigrator()
        registerBibleMigrations(&migrator)

        try migrator.migrate(queue, upTo: "v8_createBookmark")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let position = BibleReadingPositionRecord(
            bookId: "JHN", chapterNumber: 3, translationId: "KJV", updatedAt: date
        )
        let highlight = BibleHighlightRecord(
            id: "highlight", bookId: "JHN", chapterNumber: 3, verseNumber: 16,
            colorId: "yellow", createdAt: date, updatedAt: date
        )
        let bookmark = BibleBookmarkRecord(
            id: "bookmark", colorId: "red", bookId: "JHN", chapterNumber: 3, createdAt: date
        )
        let note = BibleNoteRecord(
            id: "note", target: .verse, bookId: "JHN", chapterNumber: 3,
            verseStart: 16, verseEnd: 17, body: "Keep my note", source: .user,
            createdAt: date, updatedAt: date
        )
        // One legacy multi-card row, inserted raw against the v5 shape
        // (category as its Int raw value), plus a finished bulk-ledger run
        // whose `done` unit asserts that row exists — v9 must clear both,
        // or a resumed run would report chapters annotated whose rows the
        // rebuild just dropped.
        try queue.write { db in
            try position.insert(db)
            try highlight.insert(db)
            try bookmark.insert(db)
            try note.insert(db)
            try db.execute(
                sql: """
                INSERT INTO bibleAnnotation
                (id, target, bookId, category, title, body, source, modelId, createdAt)
                VALUES ('legacy-1', 'book', 'ROM', 2, 'Author', 'Paul.', 'user', 'm', '2026-01-01 00:00:00.000')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO bulkAnnotationRun
                (id, status, modelId, haltReason, createdAt, updatedAt, completedAt, overwriteExisting)
                VALUES ('run-1', 'completed', 'm', NULL, '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 0)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO bulkAnnotationRunUnit
                (id, runId, ordinal, kind, bookId, bookName, chapterNumber, state, attemptCount, producedCount, errorMessage, updatedAt)
                VALUES ('unit-1', 'run-1', 0, 'chapter', 'ROM', 'Romans', 1, 'done', 1, 3, NULL, '2026-01-01 00:00:00.000')
                """
            )
        }

        try migrator.migrate(queue)

        let (count, columns, indexes, runCount, unitCount) = try queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bibleAnnotation") ?? -1,
                try db.columns(in: "bibleAnnotation").map(\.name),
                try db.indexes(on: "bibleAnnotation"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bulkAnnotationRun") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bulkAnnotationRunUnit") ?? -1
            )
        }
        #expect(count == 0, "legacy rows are dropped, not migrated")
        #expect(columns.contains("summary"))
        #expect(!columns.contains("category"))
        #expect(!columns.contains("title"))
        #expect(!columns.contains("body"))
        #expect(indexes.contains { $0.name == "bibleAnnotation_on_bookId_chapterNumber_verseEnd" })
        #expect(indexes.contains { $0.name == "bibleAnnotation_on_target_bookId" })
        #expect(runCount == 0, "ledger runs are cleared with the table they describe")
        // Units are deleted explicitly — the v6 cascade doesn't fire inside
        // migrations (DatabaseMigrator runs with foreign keys off).
        #expect(unitCount == 0, "ledger units are cleared with their runs")
        // v9 intentionally drops annotations and their ledger, while preserving
        // unrelated reader state and user-authored content byte for byte.
        let preserved = try queue.read { db in
            (
                try BibleReadingPositionRecord.fetchAll(db),
                try BibleHighlightRecord.fetchAll(db),
                try BibleBookmarkRecord.fetchAll(db),
                try BibleNoteRecord.fetchAll(db)
            )
        }
        #expect(preserved.0 == [position])
        #expect(preserved.1 == [highlight])
        #expect(preserved.2 == [bookmark])
        #expect(preserved.3 == [note])
    }
}
