import Foundation
import Testing
@testable import Bible

/// Tests for `BundledBibleTextSearcher` — the FTS5 query path: term matching,
/// multi-term AND, translation and book scoping, the result limit, BM25 ranking,
/// porter stemming, and the FTS-operator sanitization that keeps arbitrary input
/// from producing a malformed MATCH.
///
/// Runs against `BibleTextDatabase.makeInMemory(verses:)` — the same schema the
/// shipped artifact uses — so the suite is fast and independent of the 30 MB
/// bundled file (the bundled artifact itself is guarded by
/// `BibleTextDatabaseTests`).
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
        // Same unique term under a different translation, to prove the filter.
        .init(translation: .asv, bookId: "PSA", chapter: 23, verse: 1,
              text: "Jehovah is my shepherd; I shall not want."),
    ]

    @Test("a single term returns the matching verse")
    func singleTerm() async throws {
        let searcher = try makeSearcher(Self.fixture)
        let hits = try await searcher.search(query: "shepherd", translation: .kjv, bookId: nil, limit: 20)
        #expect(hits.count == 1)
        #expect(hits.first?.bookId == "PSA")
        #expect(hits.first?.chapter == 23)
        #expect(hits.first?.verse == 1)
    }

    @Test("multiple terms are ANDed — all must be present")
    func multiTermAnd() async throws {
        let searcher = try makeSearcher(Self.fixture)
        // "loved" and "world" co-occur only in John 3:16.
        let hits = try await searcher.search(query: "loved world", translation: .kjv, bookId: nil, limit: 20)
        #expect(hits.count == 1)
        #expect(hits.first?.verse == 16)
    }

    @Test("the translation filter isolates results to one translation")
    func translationFilter() async throws {
        let searcher = try makeSearcher(Self.fixture)
        // "shepherd" appears in both KJV and ASV Psalm 23:1; each translation
        // sees only its own row, never the other's near-duplicate.
        let kjv = try await searcher.search(query: "shepherd", translation: .kjv, bookId: nil, limit: 20)
        let asv = try await searcher.search(query: "shepherd", translation: .asv, bookId: nil, limit: 20)
        #expect(kjv.count == 1)
        #expect(asv.count == 1)
        // Same coordinates, but the KJV text mentions "LORD" and the ASV
        // "Jehovah" — proof each came from its own translation's row.
        #expect(kjv.first?.text.contains("LORD") == true)
        #expect(asv.first?.text.contains("Jehovah") == true)
    }

    @Test("the book scope limits the search to one book")
    func bookScope() async throws {
        let searcher = try makeSearcher(Self.fixture)
        // "God" appears in John 3:16, 3:17, and Romans 8:28; scoping to John
        // drops the Romans hit.
        let all = try await searcher.search(query: "God", translation: .kjv, bookId: nil, limit: 20)
        let john = try await searcher.search(query: "God", translation: .kjv, bookId: "JHN", limit: 20)
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
        let hits = try await searcher.search(query: "alpha", translation: .kjv, bookId: nil, limit: 2)
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
        let hits = try await searcher.search(query: "grace", translation: .kjv, bookId: nil, limit: 20)
        #expect(hits.count == 2)
        // Verse 1 packs three "grace" tokens into a short verse — BM25 ranks it
        // above the longer, single-mention verse 2.
        #expect(hits.first?.verse == 1)
    }

    @Test("porter stemming matches inflected forms")
    func stemming() async throws {
        let searcher = try makeSearcher(Self.fixture)
        // The fixture has "loved", never the bare "love" — porter stemming finds
        // it anyway.
        let hits = try await searcher.search(query: "love", translation: .kjv, bookId: nil, limit: 20)
        #expect(hits.contains { $0.verse == 16 })
    }

    @Test("a query with no match returns no results")
    func noMatch() async throws {
        let searcher = try makeSearcher(Self.fixture)
        let hits = try await searcher.search(query: "zebra", translation: .kjv, bookId: nil, limit: 20)
        #expect(hits.isEmpty)
    }

    @Test("FTS operators in the raw query are neutralized, never throw")
    func ftsOperatorsSanitized() async throws {
        let searcher = try makeSearcher(Self.fixture)
        // Bare `"`, `*`, `(`, `)`, `,`, `!` would each break or change a raw
        // FTS5 MATCH; sanitization strips them, leaving the searchable words
        // `world` and `loved`, both present in John 3:16.
        let hits = try await searcher.search(
            query: "  \"world\", (loved)! *", translation: .kjv, bookId: nil, limit: 20
        )
        #expect(hits.contains { $0.verse == 16 })

        // A query made entirely of operators / words absent from the corpus must
        // still complete without throwing a malformed-MATCH error.
        let safe = try await searcher.search(
            query: "OR AND NEAR( -: *", translation: .kjv, bookId: nil, limit: 20
        )
        #expect(safe.isEmpty)
    }

    @Test("a query with no searchable terms returns no results")
    func blankQuery() async throws {
        let searcher = try makeSearcher(Self.fixture)
        #expect(try await searcher.search(query: "   ", translation: .kjv, bookId: nil, limit: 20).isEmpty)
        #expect(try await searcher.search(query: "!!! ... ;:", translation: .kjv, bookId: nil, limit: 20).isEmpty)
    }

    @Test("the FTS match builder rejects empty input and quotes terms")
    func ftsMatchBuilder() {
        #expect(BundledBibleTextSearcher.ftsMatch(for: "  ") == nil)
        #expect(BundledBibleTextSearcher.ftsMatch(for: "!!!") == nil)
        #expect(BundledBibleTextSearcher.ftsMatch(for: "love grace") == "\"love\" \"grace\"")
        #expect(BundledBibleTextSearcher.ftsMatch(for: "\"love\" OR (x*") == "\"love\" \"OR\" \"x\"")
    }
}
