import Foundation
import Testing
@testable import Bible

/// Uses the shipped schema in memory; BibleTextDatabaseTests covers the bundled artifact.
@Suite("BundledBibleTextSearcher")
struct BundledBibleTextSearcherTests {
    private func makeSearcher(_ verses: [BibleTextDatabase.Row]) throws -> BundledBibleTextSearcher {
        BundledBibleTextSearcher(database: try BibleTextDatabase.makeInMemory(verses: verses))
    }

    private static let fixture: [BibleTextDatabase.Row] = [
        .init(translation: .kjv, bookId: "JHN", chapter: 3, verse: 16,
              text: "For God so loved the world, that he gave his only begotten Son."),
        .init(translation: .kjv, bookId: "JHN", chapter: 3, verse: 17,
              text: "For God sent not his Son into the world to condemn the world."),
        .init(translation: .kjv, bookId: "PSA", chapter: 23, verse: 1,
              text: "The LORD is my shepherd; I shall not want."),
        .init(translation: .kjv, bookId: "ROM", chapter: 8, verse: 28,
              text: "All things work together for good to them that love God."),
        .init(translation: .asv, bookId: "PSA", chapter: 23, verse: 1,
              text: "Jehovah is my shepherd; I shall not want."),
    ]

    @Test("a single term returns the matching verse")
    func singleTerm() async throws {
        let searcher = try makeSearcher(Self.fixture)
        let hits = try await searcher.search(query: "shepherd", translation: .kjv, bookId: nil, mode: .any, limit: 20)
        #expect(hits.count == 1)
        #expect(hits.first?.bookId == "PSA")
        #expect(hits.first?.chapter == 23)
        #expect(hits.first?.verse == 1)
    }

    @Test("match .all ANDs the terms — all must be present")
    func multiTermAll() async throws {
        let searcher = try makeSearcher(Self.fixture)
        let hits = try await searcher.search(query: "loved world", translation: .kjv, bookId: nil, mode: .all, limit: 20)
        #expect(hits.count == 1)
        #expect(hits.first?.verse == 16)
    }

    @Test("match .any ORs the terms — widens beyond .all, best-matching verse ranks first")
    func multiTermAny() async throws {
        let searcher = try makeSearcher(Self.fixture)
        // Porter stemming admits Romans through love/loved; John matches both terms and ranks first.
        let hits = try await searcher.search(query: "loved world", translation: .kjv, bookId: nil, mode: .any, limit: 20)
        let verses = Set(hits.map(\.verse))
        #expect(verses.isSuperset(of: [16, 17]))
        #expect(hits.contains { $0.bookId == "ROM" })
        #expect(hits.first?.verse == 16)
    }

    @Test("match .phrase requires the words contiguous and in order")
    func phraseRequiresContiguity() async throws {
        let verses = [
            BibleTextDatabase.Row(translation: .kjv, bookId: "MAT", chapter: 5, verse: 44,
                                  text: "Love your enemies, bless them that curse you."),
            BibleTextDatabase.Row(translation: .kjv, bookId: "LUK", chapter: 6, verse: 27,
                                  text: "Love them, and pray for your enemies."),
        ]
        let searcher = try makeSearcher(verses)

        let phrase = try await searcher.search(query: "love your enemies", translation: .kjv, bookId: nil, mode: .phrase, limit: 20)
        #expect(phrase.map(\.verse) == [44])

        // A mode change must admit both rows, proving phrase filtering caused the exclusion.
        let any = try await searcher.search(query: "love your enemies", translation: .kjv, bookId: nil, mode: .any, limit: 20)
        #expect(Set(any.map(\.verse)) == [44, 27])
    }

    @Test("the translation filter isolates results to one translation")
    func translationFilter() async throws {
        let searcher = try makeSearcher(Self.fixture)
        let kjv = try await searcher.search(query: "shepherd", translation: .kjv, bookId: nil, mode: .any, limit: 20)
        let asv = try await searcher.search(query: "shepherd", translation: .asv, bookId: nil, mode: .any, limit: 20)
        #expect(kjv.count == 1)
        #expect(asv.count == 1)
        #expect(kjv.first?.text.contains("LORD") == true)
        #expect(asv.first?.text.contains("Jehovah") == true)
    }

    @Test("the book scope limits the search to one book")
    func bookScope() async throws {
        let searcher = try makeSearcher(Self.fixture)
        let all = try await searcher.search(query: "God", translation: .kjv, bookId: nil, mode: .any, limit: 20)
        let john = try await searcher.search(query: "God", translation: .kjv, bookId: "JHN", mode: .any, limit: 20)
        #expect(all.contains { $0.bookId == "ROM" })
        #expect(john.allSatisfy { $0.bookId == "JHN" })
        #expect(!john.isEmpty)
    }

    @Test("the limit caps the number of results")
    func limitCaps() async throws {
        let verses = (1...5).map { number in
            BibleTextDatabase.Row(
                translation: .kjv, bookId: "GEN", chapter: 1, verse: number,
                text: "alpha verse number \(number)"
            )
        }
        let searcher = try makeSearcher(verses)
        let hits = try await searcher.search(query: "alpha", translation: .kjv, bookId: nil, mode: .any, limit: 2)
        #expect(hits.count == 2)
    }

    @Test("results are ranked by relevance — higher term frequency ranks first")
    func ranking() async throws {
        let verses = [
            BibleTextDatabase.Row(translation: .kjv, bookId: "GEN", chapter: 1, verse: 1,
                                  text: "grace and more grace and still more grace"),
            BibleTextDatabase.Row(translation: .kjv, bookId: "GEN", chapter: 1, verse: 2,
                                  text: "by grace you stand firm and steadfast every single day"),
        ]
        let searcher = try makeSearcher(verses)
        let hits = try await searcher.search(query: "grace", translation: .kjv, bookId: nil, mode: .any, limit: 20)
        #expect(hits.count == 2)
        // BM25 favors repeated grace in a short verse over one mention in a longer verse.
        #expect(hits.first?.verse == 1)
    }

    @Test("porter stemming matches inflected forms")
    func stemming() async throws {
        let searcher = try makeSearcher(Self.fixture)
        // The fixture contains loved, not love, so this requires stemming.
        let hits = try await searcher.search(query: "love", translation: .kjv, bookId: nil, mode: .any, limit: 20)
        #expect(hits.contains { $0.verse == 16 })
    }

    @Test("a query with no match returns no results")
    func noMatch() async throws {
        let searcher = try makeSearcher(Self.fixture)
        let hits = try await searcher.search(query: "zebra", translation: .kjv, bookId: nil, mode: .any, limit: 20)
        #expect(hits.isEmpty)
    }

    @Test("FTS operators in the raw query are neutralized, never throw")
    func ftsOperatorsSanitized() async throws {
        let searcher = try makeSearcher(Self.fixture)
        // Raw punctuation could break/change FTS MATCH; sanitization must retain searchable words.
        let hits = try await searcher.search(
            query: "  \"world\", (loved)! *", translation: .kjv, bookId: nil, mode: .any, limit: 20
        )
        #expect(hits.contains { $0.verse == 16 })

        let safe = try await searcher.search(
            query: "OR AND NEAR( -: *", translation: .kjv, bookId: nil, mode: .any, limit: 20
        )
        #expect(safe.isEmpty)
    }

    @Test("a query with no searchable terms returns no results")
    func blankQuery() async throws {
        let searcher = try makeSearcher(Self.fixture)
        #expect(try await searcher.search(query: "   ", translation: .kjv, bookId: nil, mode: .any, limit: 20).isEmpty)
        #expect(try await searcher.search(query: "!!! ... ;:", translation: .kjv, bookId: nil, mode: .any, limit: 20).isEmpty)
    }

    @Test("the FTS match builder rejects empty input and joins terms per mode")
    func ftsMatchBuilder() {
        #expect(BundledBibleTextSearcher.ftsMatch(for: "  ", mode: .any) == nil)
        #expect(BundledBibleTextSearcher.ftsMatch(for: "!!!", mode: .all) == nil)

        #expect(BundledBibleTextSearcher.ftsMatch(for: "love grace", mode: .any) == "\"love\" OR \"grace\"")
        #expect(BundledBibleTextSearcher.ftsMatch(for: "love grace", mode: .all) == "\"love\" \"grace\"")
        #expect(BundledBibleTextSearcher.ftsMatch(for: "love grace", mode: .phrase) == "\"love grace\"")

        #expect(BundledBibleTextSearcher.ftsMatch(for: "\"love\" OR (x*", mode: .all) == "\"love\" \"OR\" \"x\"")
    }
}
