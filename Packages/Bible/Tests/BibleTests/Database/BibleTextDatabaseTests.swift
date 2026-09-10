import Foundation
import GRDB
import Testing
@testable import Bible

/// Checks flat verse/FTS data; DatabaseBibleTextLoaderParityTests separately covers structured chapter blobs.
@Suite("BibleTextDatabase bundled artifact")
struct BibleTextDatabaseTests {
    private struct VerseRow: FetchableRecord, Decodable {
        let translation: String
        let bookId: String
        let chapter: Int
        let verse: Int
        let text: String
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
        // Cover every translation, both Testaments, prose, poetry, and a verse spanning a poetry boundary.
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
