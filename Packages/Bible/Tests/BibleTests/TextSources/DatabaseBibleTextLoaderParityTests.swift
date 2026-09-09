import Foundation
import GRDB
import Testing
@testable import Bible

/// Exhaustive bundled database/JSON equality and verse-contiguity checks share
/// one decode of each JSON book. All 4,756 chapters remain covered; each
/// translation owns an independent database connection and test invocation.
@Suite("DatabaseBibleTextLoader parity with the JSON oracle")
struct DatabaseBibleTextLoaderParityTests {
    @Test("every chapter matches JSON and preserves verse continuity", arguments: BibleTranslation.allCases)
    func everyChapterMatches(_ translation: BibleTranslation) throws {
        let database = try BibleTextDatabase.openBundled()
        let dbLoader = DatabaseBibleTextLoader(database: database)
        let jsonLoader = BundledBibleTextLoader()
        let catalog = BibleBookCatalog.standard
        var compared = 0
        for summary in catalog.books {
            let jsonBook = try jsonLoader.loadBook(id: summary.id, translation: translation)
            #expect(jsonBook.id == summary.id)
            #expect(jsonBook.chapters.map(\.number) == Array(1...summary.chapterCount))
            for chapterNumber in 1...summary.chapterCount {
                let fromJSON = try #require(
                    jsonBook.chapter(chapterNumber),
                    "\(translation.rawValue) \(summary.id) \(chapterNumber) missing from JSON"
                )
                let fromDB = try dbLoader.loadChapter(
                    bookId: summary.id, chapterNumber: chapterNumber, translation: translation
                )
                // A required JSON chapter prevents a vacuous nil == nil pass.
                #expect(
                    fromDB == fromJSON,
                    "\(translation.rawValue) \(summary.id) \(chapterNumber) differs between DB and JSON"
                )
                expectContiguousVerses(fromJSON, bookId: summary.id, translation: translation)
                compared += 1
            }
        }
        #expect(compared == 1_189)
        let storedCount = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM chapter WHERE translation = ?",
                             arguments: [translation.rawValue])
        }
        // Exact count also rejects unexpected chapter rows outside the catalog.
        #expect(storedCount == compared)
    }

    /// Preserves the BSB ingest regression: multiple verse markers on one source
    /// line previously disappeared. Only documented textual variants may be gaps.
    private func expectContiguousVerses(
        _ chapter: BibleChapter, bookId: String, translation: BibleTranslation
    ) {
        var present: Set<Int> = []
        for paragraph in chapter.paragraphs {
            switch paragraph {
            case .heading: continue
            case .prose(let verses), .poetry(let verses):
                present.formUnion(verses.map(\.number))
            }
        }
        guard let maxVerse = present.max(), maxVerse > 0 else {
            Issue.record("\(translation.rawValue)-\(bookId) ch\(chapter.number): no verses")
            return
        }
        for number in 1...maxVerse where !present.contains(number) {
            let position = TextualVariant(book: bookId, chapter: chapter.number, verse: number)
            #expect(
                Self.textualVariantOmissions.contains(position),
                "\(translation.rawValue)-\(bookId) ch\(chapter.number): unexpected gap at v\(number)"
            )
        }
    }

    /// A `(book, chapter, verse)` position absent from one or more critical-
    /// text translations but present in the Textus-Receptus-based KJV.
    private struct TextualVariant: Hashable {
        let book: String
        let chapter: Int
        let verse: Int
    }

    /// The 16 textual-variant verses critical-text translations (ASV, BSB) and
    /// the partially-hybrid WEB omit. KJV (Textus Receptus) includes all of
    /// them; ASV and BSB omit all 16; WEB omits a subset of 4. Any verse-gap
    /// outside this set in any bundled translation indicates a converter bug.
    private static let textualVariantOmissions: Set<TextualVariant> = [
        TextualVariant(book: "MAT", chapter: 17, verse: 21),
        TextualVariant(book: "MAT", chapter: 18, verse: 11),
        TextualVariant(book: "MAT", chapter: 23, verse: 14),
        TextualVariant(book: "MRK", chapter: 7, verse: 16),
        TextualVariant(book: "MRK", chapter: 9, verse: 44),
        TextualVariant(book: "MRK", chapter: 9, verse: 46),
        TextualVariant(book: "MRK", chapter: 11, verse: 26),
        TextualVariant(book: "MRK", chapter: 15, verse: 28),
        TextualVariant(book: "LUK", chapter: 17, verse: 36),
        TextualVariant(book: "LUK", chapter: 23, verse: 17),
        TextualVariant(book: "JHN", chapter: 5, verse: 4),
        TextualVariant(book: "ACT", chapter: 8, verse: 37),
        TextualVariant(book: "ACT", chapter: 15, verse: 34),
        TextualVariant(book: "ACT", chapter: 24, verse: 7),
        TextualVariant(book: "ACT", chapter: 28, verse: 29),
        TextualVariant(book: "ROM", chapter: 16, verse: 24),
    ]
}
