import Foundation
import Testing
@testable import Bible

/// Tests for `BundledBibleTextLoader` — loading a real bundled book in each
/// translation, the missing- and malformed-resource error paths, and that the
/// three translations resolve to genuinely different text.
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
        // 1 Peter 2 opens with a prose paragraph whose first verse is 1.
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

    @Test("the three translations carry distinct text")
    func translationsDiffer() throws {
        let loader = BundledBibleTextLoader()
        let web = try loader.loadBook(id: "1PE", translation: .web)
        let kjv = try loader.loadBook(id: "1PE", translation: .kjv)
        let asv = try loader.loadBook(id: "1PE", translation: .asv)
        // Same book identity, different rendered text — proof the loader keyed
        // each read to the right resource rather than always reading WEB.
        #expect(web.chapters != kjv.chapters)
        #expect(web.chapters != asv.chapters)
        #expect(kjv.chapters != asv.chapters)
    }

    @Test("an unknown book id throws bookNotFound")
    func missingBookThrows() {
        #expect(throws: BibleTextLoaderError.bookNotFound("ZZZ")) {
            try BundledBibleTextLoader().loadBook(id: "ZZZ", translation: .web)
        }
    }

    @Test("a malformed resource throws malformedResource")
    func malformedResourceThrows() {
        // `.module` here is the BibleTests target bundle, into which
        // `Fixtures/WEB-BAD.json` (invalid JSON) is processed — the real
        // 198 resources live in a separate bundle, so pointing the loader
        // here isolates the malformed-resource path.
        let loader = BundledBibleTextLoader(bundle: .module)
        #expect(throws: BibleTextLoaderError.malformedResource("BAD")) {
            try loader.loadBook(id: "BAD", translation: .web)
        }
    }
}
