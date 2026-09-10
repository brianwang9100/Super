import Foundation
import Testing
@testable import Bible

@Suite("BundledBibleTextLoader")
struct BundledBibleTextLoaderTests {
    @Test("loads a bundled book with its chapters and paragraphs")
    func loadsRealBook() throws {
        let book = try BundledBibleTextLoader().loadBook(id: "1PE", translation: .web)
        #expect(book.id == "1PE")
        #expect(book.name == "1 Peter")
        #expect(book.testament == .newTestament)
        #expect(book.chapters.count == 5)

        let chapter = try #require(book.chapter(2))
        #expect(!chapter.paragraphs.isEmpty)
        guard case .prose(let verses) = chapter.paragraphs.first else {
            Issue.record("expected the first paragraph to be prose")
            return
        }
        #expect(verses.first?.number == 1)
    }

    @Test("a poetry paragraph survives the load")
    func loadsPoetry() throws {
        let chapter = try #require(
            try BundledBibleTextLoader().loadBook(id: "1PE", translation: .web).chapter(2)
        )
        let hasPoetry = chapter.paragraphs.contains {
            if case .poetry = $0 { return true } else { return false }
        }
        #expect(hasPoetry, "1 Peter 2 quotes Isaiah in poetry blocks")
    }

    @Test("each translation resolves its own bundled resource", arguments: BibleTranslation.allCases)
    func loadsEveryTranslation(_ translation: BibleTranslation) throws {
        let book = try BundledBibleTextLoader().loadBook(id: "1PE", translation: translation)
        #expect(book.id == "1PE")
        #expect(book.name == "1 Peter")
        #expect(book.chapters.count == 5)
    }

    @Test("every pair of bundled translations carries distinct text")
    func translationsDiffer() throws {
        let loader = BundledBibleTextLoader()
        // Different text in every translation catches an incorrectly fixed resource key.
        let books = try BibleTranslation.allCases.map {
            try loader.loadBook(id: "1PE", translation: $0)
        }
        for i in books.indices {
            for j in (i + 1)..<books.endIndex {
                #expect(books[i].chapters != books[j].chapters)
            }
        }
    }

    @Test("an unknown book id throws bookNotFound")
    func missingBookThrows() {
        #expect(throws: BibleTextLoaderError.bookNotFound("ZZZ")) {
            try BundledBibleTextLoader().loadBook(id: "ZZZ", translation: .web)
        }
    }

    @Test("a malformed resource throws malformedResource")
    func malformedResourceThrows() {
        // This target bundle contains malformed WEB-BAD.json, separate from the real text fixtures.
        let loader = BundledBibleTextLoader(bundle: .module)
        #expect(throws: BibleTextLoaderError.malformedResource("BAD")) {
            try loader.loadBook(id: "BAD", translation: .web)
        }
    }
}
