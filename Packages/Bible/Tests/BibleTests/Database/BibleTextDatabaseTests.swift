import Foundation
import GRDB
import Testing
@testable import Bible

/// Guards the committed `bible-text.sqlite` artifact against the JSON it's built
/// from. The database is generated offline by a Python script
/// (`Scripts/generate_bible_text_sqlite.py`); this suite opens the *real* bundled
/// artifact and checks both layers: the flat `verse`/FTS search rows (diffed
/// against the Swift `coalescedVerses()` path the script reimplements) and the
/// structured `chapter` blobs (decoded back into `BibleChapter` and compared to the
/// JSON loader). The samples catch systematic regeneration staleness and any
/// divergence in the shared rules; a localized single-book edit that misses the
/// sampled chapters would slip through, but the count bounds below still flag gross
/// staleness.
@Suite("BibleTextDatabase bundled artifact")
struct BibleTextDatabaseTests {
    /// One verse row from the bundled `verse` table.
    private struct VerseRow: FetchableRecord, Decodable {
        let translation: String
        let bookId: String
        let chapter: Int
        let verse: Int
        let text: String
    }

    @Test("the bundled FTS database opens and is fully populated")
    func opensAndPopulated() throws {
        let database = try BibleTextDatabase.openBundled()
        let count = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM verse") ?? 0
        }
        // ~31k verses × 4 translations; assert a generous lower bound rather than
        // an exact count so an unrelated text fix doesn't churn this test.
        #expect(count > 120_000)
    }

    @Test("a known verse is present with its exact text")
    func knownVerse() throws {
        let database = try BibleTextDatabase.openBundled()
        let text = try database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT text FROM verse WHERE translation = ? AND bookId = ? AND chapter = ? AND verse = ?",
                arguments: ["KJV", "JHN", 3, 16]
            )
        }
        #expect(text == "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life.")
    }

    @Test("every translation is represented")
    func allTranslationsPresent() throws {
        let database = try BibleTextDatabase.openBundled()
        for translation in BibleTranslation.allCases {
            let count = try database.queue.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM verse WHERE translation = ?",
                    arguments: [translation.rawValue]
                ) ?? 0
            }
            #expect(count > 30_000, "\(translation.rawValue) should have a full canon")
        }
    }

    @Test("DB verse text matches the Swift-coalesced JSON across translations")
    func matchesCoalescedJSON() throws {
        let database = try BibleTextDatabase.openBundled()
        let loader = BundledBibleTextLoader()
        // A spread across all four translations and Testaments — prose, poetry,
        // and a verse known to span a poetry boundary all get covered.
        let samples: [(BibleTranslation, String, Int)] = [
            (.kjv, "JHN", 3),
            (.web, "PSA", 23),
            (.asv, "GEN", 1),
            (.bsb, "ROM", 8),
        ]
        for (translation, bookId, chapterNumber) in samples {
            let book = try loader.loadBook(id: bookId, translation: translation)
            let chapter = try #require(book.chapter(chapterNumber))
            for verse in chapter.coalescedVerses() {
                let dbText = try database.queue.read { db in
                    try String.fetchOne(
                        db,
                        sql: "SELECT text FROM verse WHERE translation = ? AND bookId = ? AND chapter = ? AND verse = ?",
                        arguments: [translation.rawValue, bookId, chapterNumber, verse.number]
                    )
                }
                #expect(
                    dbText == verse.text,
                    "\(translation.rawValue) \(bookId) \(chapterNumber):\(verse.number) drifted from the JSON"
                )
            }
        }
    }

    // MARK: - Structured chapter table

    @Test("every translation's full canon is present in the chapter table")
    func chapterTablePopulated() throws {
        let database = try BibleTextDatabase.openBundled()
        for translation in BibleTranslation.allCases {
            let books = try database.queue.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT count(DISTINCT bookId) FROM chapter WHERE translation = ?",
                    arguments: [translation.rawValue]
                ) ?? 0
            }
            #expect(books == 66, "\(translation.rawValue) should have all 66 books")
        }
        let chapters = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM chapter") ?? 0
        }
        // 1,189 chapters in the Protestant canon × 4 full-canon translations.
        // A lower bound so an unrelated text fix doesn't churn this test.
        #expect(chapters > 4_700)
    }

    @Test("a stored chapter blob decodes to the same BibleChapter the JSON loader yields")
    func chapterBlobDecodesToBibleChapter() throws {
        let database = try BibleTextDatabase.openBundled()
        let loader = BundledBibleTextLoader()
        // Prose (JHN 3) and a heading-plus-poetry chapter (PSA 23) cover the two
        // paragraph shapes the blob round-trips.
        let samples: [(BibleTranslation, String, Int)] = [
            (.kjv, "JHN", 3),
            (.web, "PSA", 23),
        ]
        let decoder = JSONDecoder()
        for (translation, bookId, chapterNumber) in samples {
            let blob = try #require(try database.queue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT json FROM chapter WHERE translation = ? AND bookId = ? AND number = ?",
                    arguments: [translation.rawValue, bookId, chapterNumber]
                )
            })
            let decoded = try decoder.decode(BibleChapter.self, from: Data(blob.utf8))
            let expected = try #require(
                try loader.loadBook(id: bookId, translation: translation).chapter(chapterNumber)
            )
            #expect(
                decoded == expected,
                "\(translation.rawValue) \(bookId) \(chapterNumber) blob drifted from the JSON"
            )
        }
    }

    @Test("the FTS index is queryable and returns the indexed verse")
    func ftsQueryable() throws {
        let database = try BibleTextDatabase.openBundled()
        let rows = try database.queue.read { db in
            try VerseRow.fetchAll(
                db,
                sql: """
                SELECT v.translation AS translation, v.bookId AS bookId, v.chapter AS chapter,
                       v.verse AS verse, v.text AS text
                FROM verse_fts JOIN verse v ON v.id = verse_fts.rowid
                WHERE verse_fts MATCH ? AND v.translation = ?
                ORDER BY bm25(verse_fts) LIMIT 5
                """,
                arguments: ["\"shepherd\"", "KJV"]
            )
        }
        #expect(!rows.isEmpty)
        #expect(rows.contains { $0.bookId == "PSA" && $0.chapter == 23 && $0.verse == 1 })
    }
}
