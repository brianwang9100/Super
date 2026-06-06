import Foundation
import Testing
@testable import Bible

/// The decisive guard for the DB-reader consolidation: for **every** translation ×
/// book × chapter, the production `DatabaseBibleTextLoader` (reading the bundled
/// `bible-text.sqlite`) must return a `BibleChapter` equal to the one
/// `BundledBibleTextLoader` decodes from the source JSON.
///
/// `BibleChapter` is `Equatable`, so equality across all ~4,756 chapters proves the
/// reader renders byte-for-byte identically off the database — which is what
/// licenses *not* re-recording the reader snapshot baselines when the fixtures
/// switch to the DB loader. A failure here is a real generator bug to fix, never a
/// snapshot re-record.
@Suite("DatabaseBibleTextLoader parity with the JSON oracle")
struct DatabaseBibleTextLoaderParityTests {
    @Test("every translation × book × chapter decodes identically from DB and JSON")
    func everyChapterMatches() throws {
        let dbLoader = DatabaseBibleTextLoader()
        let jsonLoader = BundledBibleTextLoader()
        let catalog = BibleBookCatalog.standard
        var compared = 0
        for translation in BibleTranslation.allCases {
            for summary in catalog.books {
                // Decode the JSON book once, then compare each of its chapters to
                // the DB loader's per-chapter result — far cheaper than re-decoding
                // the whole book per chapter, same guarantee.
                let jsonBook = try jsonLoader.loadBook(id: summary.id, translation: translation)
                for chapterNumber in 1...summary.chapterCount {
                    let fromDB = try dbLoader.loadChapter(
                        bookId: summary.id, chapterNumber: chapterNumber, translation: translation
                    )
                    let fromJSON = jsonBook.chapter(chapterNumber)
                    #expect(
                        fromDB == fromJSON,
                        "\(translation.rawValue) \(summary.id) \(chapterNumber) differs between DB and JSON"
                    )
                    // Both sources must actually have the chapter — a silent
                    // nil == nil would pass vacuously and hide a missing canon.
                    #expect(fromDB != nil, "\(translation.rawValue) \(summary.id) \(chapterNumber) missing from DB")
                    compared += 1
                }
            }
        }
        // 1,189 chapters × 4 full-canon translations.
        #expect(compared == 1_189 * BibleTranslation.allCases.count)
    }
}
