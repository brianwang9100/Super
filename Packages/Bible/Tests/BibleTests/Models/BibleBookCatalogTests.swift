import Core
import Testing
@testable import Bible

@Suite("BibleBookCatalog")
struct BibleBookCatalogTests {
    private let catalog = BibleBookCatalog.standard

    @Test("the canon has 66 books, Genesis first and Revelation last")
    func canonShape() {
        #expect(catalog.books.count == 66)
        #expect(catalog.books.first?.id == "GEN")
        #expect(catalog.books.last?.id == "REV")
    }

    @Test("stepping forward within a book increments the chapter")
    func stepForwardWithinBook() {
        let next = catalog.step(
            from: BiblePosition(bookId: "1PE", chapterNumber: 2),
            direction: .next
        )
        #expect(next == BiblePosition(bookId: "1PE", chapterNumber: 3))
    }

    @Test("stepping backward within a book decrements the chapter")
    func stepBackwardWithinBook() {
        let previous = catalog.step(
            from: BiblePosition(bookId: "1PE", chapterNumber: 2),
            direction: .previous
        )
        #expect(previous == BiblePosition(bookId: "1PE", chapterNumber: 1))
    }

    @Test("stepping forward past the last chapter wraps to the next book")
    func stepForwardCrossesBookBoundary() {
        let next = catalog.step(
            from: BiblePosition(bookId: "GEN", chapterNumber: 50),
            direction: .next
        )
        #expect(next == BiblePosition(bookId: "EXO", chapterNumber: 1))
    }

    @Test("stepping backward from a first chapter wraps to the previous book's last")
    func stepBackwardCrossesBookBoundary() {
        let previous = catalog.step(
            from: BiblePosition(bookId: "EXO", chapterNumber: 1),
            direction: .previous
        )
        #expect(previous == BiblePosition(bookId: "GEN", chapterNumber: 50))
    }

    @Test("there is no chapter before Genesis 1")
    func noStepBeforeGenesis() {
        #expect(catalog.step(
            from: BiblePosition(bookId: "GEN", chapterNumber: 1),
            direction: .previous
        ) == nil)
    }

    @Test("there is no chapter after Revelation 22")
    func noStepAfterRevelation() {
        #expect(catalog.step(
            from: BiblePosition(bookId: "REV", chapterNumber: 22),
            direction: .next
        ) == nil)
    }

    @Test("stepping from an unknown book id yields nil")
    func unknownBookYieldsNil() {
        #expect(catalog.step(
            from: BiblePosition(bookId: "ZZZ", chapterNumber: 1),
            direction: .next
        ) == nil)
    }

    @Test(
        "every catalog entry matches every bundled translation",
        arguments: BibleTranslation.allCases
    )
    func catalogMatchesBundledText(_ translation: BibleTranslation) throws {
        let loader = BundledBibleTextLoader()
        for summary in catalog.books {
            // Loading every book also catches missing resources that would strand the reader.
            let book = try loader.loadBook(id: summary.id, translation: translation)
            #expect(book.name == summary.name, "name mismatch for \(translation.rawValue)-\(summary.id)")
            #expect(
                book.testament == summary.testament,
                "testament mismatch for \(translation.rawValue)-\(summary.id)"
            )
            #expect(
                book.chapters.count == summary.chapterCount,
                "chapter count mismatch for \(translation.rawValue)-\(summary.id)"
            )
        }
    }

    @Test("Bible's catalog and Core's parser index agree on every book")
    func catalogAgreesWithCoreIndex() {
        // Core linkifies Chat citations while Bible independently validates reader targets.
        // Keep both catalogs in sync so generated links remain openable.
        let catalogRows = catalog.books.map { ($0.id, $0.name, $0.chapterCount) }
        let indexRows = BibleBookIndex.canonical.map { ($0.id, $0.name, $0.chapterCount) }
        #expect(catalogRows.count == indexRows.count)
        for (catalogRow, indexRow) in zip(catalogRows, indexRows) {
            #expect(catalogRow.0 == indexRow.0, "id mismatch: catalog=\(catalogRow.0) index=\(indexRow.0)")
            #expect(catalogRow.1 == indexRow.1, "name mismatch for \(catalogRow.0): catalog=\(catalogRow.1) index=\(indexRow.1)")
            #expect(catalogRow.2 == indexRow.2, "chapterCount mismatch for \(catalogRow.0): catalog=\(catalogRow.2) index=\(indexRow.2)")
        }
    }

    // MARK: - resolve(bookName:)

    @Test("resolve matches a three-letter id case-insensitively")
    func resolveMatchesId() {
        #expect(catalog.resolve(bookName: "1pe")?.id == "1PE")
        #expect(catalog.resolve(bookName: "GEN")?.id == "GEN")
    }

    @Test("resolve matches a full display name ignoring whitespace and case")
    func resolveMatchesName() {
        #expect(catalog.resolve(bookName: "1 Peter")?.id == "1PE")
        #expect(catalog.resolve(bookName: "1peter")?.id == "1PE")
        #expect(catalog.resolve(bookName: "song of solomon")?.id == "SNG")
    }

    @Test("resolve accepts a unique prefix of the display name")
    func resolveMatchesUniquePrefix() {
        #expect(catalog.resolve(bookName: "Gen")?.id == "GEN")
        #expect(catalog.resolve(bookName: "Phile")?.id == "PHM")   // only Philemon
    }

    @Test("resolve rejects an ambiguous prefix")
    func resolveRejectsAmbiguousPrefix() {
        #expect(catalog.resolve(bookName: "Phil") == nil)          // Philippians + Philemon
        #expect(catalog.resolve(bookName: "J") == nil)
    }

    @Test("resolve rejects an empty or whitespace-only candidate")
    func resolveRejectsEmpty() {
        #expect(catalog.resolve(bookName: "") == nil)
        #expect(catalog.resolve(bookName: "   ") == nil)
    }
}
