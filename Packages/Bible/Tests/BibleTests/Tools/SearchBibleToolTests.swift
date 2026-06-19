import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `SearchBibleTool` — the `bible.search` content lookup: query
/// validation, translation resolution + fallback, optional book scoping, limit
/// clamping, the numbered output contract, and the empty-result (non-error)
/// contract.
@Suite("SearchBibleTool")
struct SearchBibleToolTests {
    private func makeTool(
        hits: [BibleVerseMatch] = [],
        currentTranslation: String? = nil,
        positionAvailable: Bool = true
    ) -> (tool: SearchBibleTool, searcher: RecordingSearcher) {
        let searcher = RecordingSearcher(hits: hits)
        let repository: (any BibleReadingPositionRepository)? = positionAvailable
            ? StubPositionRepository(record: currentTranslation.map {
                BibleReadingPositionRecord(
                    bookId: "JHN", chapterNumber: 3, translationId: $0,
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            })
            : nil
        return (SearchBibleTool(searcher: searcher, positionRepository: repository), searcher)
    }

    private static let twoHits: [BibleVerseMatch] = [
        BibleVerseMatch(bookId: "PHP", chapter: 4, verse: 6, text: "Be careful for nothing."),
        BibleVerseMatch(bookId: "1PE", chapter: 5, verse: 7, text: "Casting all your care upon him."),
    ]

    // MARK: - Happy paths

    @Test("results render as a header plus one cited line per hit, ranked order preserved")
    func formatsResults() async throws {
        let (tool, _) = makeTool(hits: Self.twoHits)
        let result = try await tool.execute(input: ["query": .string("anxiety")])
        #expect(result.isError == false)
        #expect(result.content == """
        2 results for "anxiety" (KJV):

        Philippians 4:6 — Be careful for nothing.
        1 Peter 5:7 — Casting all your care upon him.
        """)
    }

    @Test("a single hit uses the singular 'result'")
    func singularHeader() async throws {
        let (tool, _) = makeTool(hits: [Self.twoHits[0]])
        let result = try await tool.execute(input: ["query": .string("careful")])
        #expect(result.content.hasPrefix("1 result for \"careful\" (KJV):"))
    }

    @Test("zero hits is a non-error result, not a failure")
    func zeroHits() async throws {
        let (tool, _) = makeTool(hits: [])
        let result = try await tool.execute(input: ["query": .string("xyzzy")])
        #expect(result.isError == false)
        #expect(result.content.contains("No verses"))
        #expect(result.content.contains("xyzzy"))
    }

    // MARK: - Query validation

    @Test("a missing query is an error")
    func missingQuery() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [:])
        #expect(result.isError == true)
        #expect(result.content.contains("query is required"))
    }

    @Test("a blank query is an error")
    func blankQuery() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: ["query": .string("   ")])
        #expect(result.isError == true)
        #expect(result.content.contains("query is required"))
    }

    // MARK: - Translation resolution

    @Test("an omitted translation uses the user's current selection")
    func omittedTranslationUsesCurrent() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits, currentTranslation: "ASV")
        let result = try await tool.execute(input: ["query": .string("anxiety")])
        #expect(result.content.contains("(ASV)"))
        #expect(await searcher.lastTranslation == .asv)
    }

    @Test("an omitted translation falls back to the default when none is stored")
    func omittedTranslationFallsBack() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits, positionAvailable: false)
        _ = try await tool.execute(input: ["query": .string("anxiety")])
        #expect(await searcher.lastTranslation == .kjv)
    }

    @Test("an explicit translation overrides the current selection, case-insensitively")
    func explicitTranslation() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits, currentTranslation: "ASV")
        let result = try await tool.execute(input: [
            "query": .string("anxiety"), "translation": .string("web"),
        ])
        #expect(result.content.contains("(WEB)"))
        #expect(await searcher.lastTranslation == .web)
    }

    @Test("an unknown translation is an error")
    func unknownTranslation() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "query": .string("anxiety"), "translation": .string("XYZ"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown translation"))
    }

    // MARK: - Book scope

    @Test("a book argument is resolved and passed to the searcher")
    func bookScopePassed() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits)
        _ = try await tool.execute(input: [
            "query": .string("grace"), "book": .string("Romans"),
        ])
        #expect(await searcher.lastBookId == "ROM")
    }

    @Test("an omitted book searches the whole canon (nil scope)")
    func bookScopeOmitted() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits)
        _ = try await tool.execute(input: ["query": .string("grace")])
        #expect(await searcher.lastBookId == nil)
    }

    @Test("an unknown book is an error")
    func unknownBook() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "query": .string("grace"), "book": .string("Nephi"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown or ambiguous book"))
    }

    @Test("an ambiguous book prefix is an error")
    func ambiguousBook() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "query": .string("grace"), "book": .string("Jo"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown or ambiguous book"))
    }

    // MARK: - Limit

    @Test("the limit defaults to 20 when omitted")
    func limitDefaults() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits)
        _ = try await tool.execute(input: ["query": .string("grace")])
        #expect(await searcher.lastLimit == SearchBibleTool.defaultLimit)
    }

    @Test("an over-large limit clamps to the maximum")
    func limitClampsHigh() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits)
        _ = try await tool.execute(input: ["query": .string("grace"), "limit": .int(9999)])
        #expect(await searcher.lastLimit == SearchBibleTool.maxLimit)
    }

    @Test("a non-positive limit clamps to one")
    func limitClampsLow() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits)
        _ = try await tool.execute(input: ["query": .string("grace"), "limit": .int(0)])
        #expect(await searcher.lastLimit == 1)
    }

    // MARK: - Match mode

    @Test("an omitted match defaults to the forgiving `any`")
    func matchDefaultsToAny() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits)
        _ = try await tool.execute(input: ["query": .string("anxiety hope")])
        #expect(await searcher.lastMode == .any)
    }

    @Test("match 'all' and 'phrase' are passed through to the searcher")
    func matchExplicitModes() async throws {
        let (allTool, allSearcher) = makeTool(hits: Self.twoHits)
        _ = try await allTool.execute(input: ["query": .string("loved world"), "match": .string("all")])
        #expect(await allSearcher.lastMode == .all)

        let (phraseTool, phraseSearcher) = makeTool(hits: Self.twoHits)
        _ = try await phraseTool.execute(input: ["query": .string("love your enemies"), "match": .string("phrase")])
        #expect(await phraseSearcher.lastMode == .phrase)
    }

    @Test("an unknown match value falls back to `any`, not an error")
    func matchUnknownFallsBack() async throws {
        let (tool, searcher) = makeTool(hits: Self.twoHits)
        let result = try await tool.execute(input: ["query": .string("grace"), "match": .string("fuzzy")])
        #expect(result.isError == false)
        #expect(await searcher.lastMode == .any)
    }
}

// MARK: - Test doubles

/// A `BibleTextSearching` that records the arguments of the last call and
/// returns a fixed result set, so tests can assert both formatting and argument
/// plumbing.
private actor RecordingSearcher: BibleTextSearching {
    let hits: [BibleVerseMatch]
    private(set) var lastTranslation: BibleTranslation?
    private(set) var lastBookId: String?
    private(set) var lastMode: BibleSearchMatchMode?
    private(set) var lastLimit: Int?

    init(hits: [BibleVerseMatch]) { self.hits = hits }

    func search(
        query: String, translation: BibleTranslation, bookId: String?,
        mode: BibleSearchMatchMode, limit: Int
    ) async throws -> [BibleVerseMatch] {
        lastTranslation = translation
        lastBookId = bookId
        lastMode = mode
        lastLimit = limit
        return hits
    }
}
