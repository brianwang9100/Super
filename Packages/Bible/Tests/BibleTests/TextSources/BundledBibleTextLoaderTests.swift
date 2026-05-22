import Foundation
import Testing
@testable import Bible

/// Tests for `BundledBibleTextLoader` — loading a real bundled book in each
/// translation, the missing- and malformed-resource error paths, and that the
/// bundled translations resolve to genuinely different text.
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

    @Test("every pair of bundled translations carries distinct text")
    func translationsDiffer() throws {
        let loader = BundledBibleTextLoader()
        // Same book identity, different rendered text in every pair — proof
        // the loader keyed each read to the right resource rather than always
        // reading WEB.
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
        // `.module` here is the BibleTests target bundle, into which
        // `Fixtures/WEB-BAD.json` (invalid JSON) is processed — the real
        // 264 resources live in a separate bundle, so pointing the loader
        // here isolates the malformed-resource path.
        let loader = BundledBibleTextLoader(bundle: .module)
        #expect(throws: BibleTextLoaderError.malformedResource("BAD")) {
            try loader.loadBook(id: "BAD", translation: .web)
        }
    }

    /// Regression test for the BSB ingest path: the converter previously
    /// dropped verses in chapters where the USFM source packed multiple
    /// `\v N` markers on one line (BSB-1CO ch 1 shipped with 13 of 31
    /// verses). Asserts that every chapter's verse numbers form a
    /// contiguous run from 1 to its maximum, *except* for the well-known
    /// textual-variant positions critical-text translations omit (Acts 8:37
    /// and friends — the Textus-Receptus-only verses).
    @Test(
        "every chapter's verse numbers are contiguous modulo textual variants",
        arguments: BibleTranslation.allCases
    )
    func verseNumbersAreContiguous(_ translation: BibleTranslation) throws {
        let loader = BundledBibleTextLoader()
        for summary in BibleBookCatalog.standard.books {
            let book = try loader.loadBook(id: summary.id, translation: translation)
            for chapter in book.chapters {
                var present: Set<Int> = []
                for paragraph in chapter.paragraphs {
                    switch paragraph {
                    case .heading: continue
                    case .prose(let verses), .poetry(let verses):
                        present.formUnion(verses.map(\.number))
                    }
                }
                guard let maxVerse = present.max() else {
                    Issue.record(
                        "\(translation.rawValue)-\(summary.id) ch\(chapter.number): no verses"
                    )
                    continue
                }
                for n in 1...maxVerse where !present.contains(n) {
                    let pos = TextualVariant(book: summary.id, chapter: chapter.number, verse: n)
                    #expect(
                        Self.textualVariantOmissions.contains(pos),
                        "\(translation.rawValue)-\(summary.id) ch\(chapter.number): unexpected gap at v\(n) — not a documented textual variant, likely a parser regression"
                    )
                }
            }
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
