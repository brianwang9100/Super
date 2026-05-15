import Testing
@testable import Bible

/// Tests for `BibleBookCatalog` — chapter stepping across book boundaries
/// and the canon's two hard ends, plus a faithfulness check that every
/// catalog entry agrees with the bundled World English Bible text.
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
        // Genesis ends at chapter 50; the next chapter is Exodus 1.
        let next = catalog.step(
            from: BiblePosition(bookId: "GEN", chapterNumber: 50),
            direction: .next
        )
        #expect(next == BiblePosition(bookId: "EXO", chapterNumber: 1))
    }

    @Test("stepping backward from a first chapter wraps to the previous book's last")
    func stepBackwardCrossesBookBoundary() {
        // Exodus 1 back is Genesis 50.
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

    @Test("every catalog entry matches the bundled WEB text")
    func catalogMatchesBundledText() throws {
        let loader = BundledBibleTextLoader()
        for summary in catalog.books {
            let book = try loader.loadBook(id: summary.id, translation: .web)
            #expect(book.name == summary.name, "name mismatch for \(summary.id)")
            #expect(book.testament == summary.testament, "testament mismatch for \(summary.id)")
            #expect(
                book.chapters.count == summary.chapterCount,
                "chapter count mismatch for \(summary.id)"
            )
        }
    }
}
