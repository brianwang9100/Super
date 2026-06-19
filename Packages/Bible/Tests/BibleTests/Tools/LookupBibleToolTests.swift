import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `LookupBibleTool` — the merged `bible.lookup` tool. The `action`
/// discriminator routes to the read and search execution cores, results are
/// re-stamped with the lookup tool id, the shared `translation` applies to both
/// actions, and the descriptor advertises the union schema (with a compact
/// variant on every top-level parameter). The per-path behavior itself is
/// covered exhaustively by `ReadBibleToolTests` / `SearchBibleToolTests`; this
/// suite covers only the routing seam.
@Suite("LookupBibleTool")
struct LookupBibleToolTests {
    private var johnBook: BibleBook {
        BibleBook(
            id: "JHN",
            name: "John",
            testament: .newTestament,
            chapters: [
                BibleChapter(number: 3, paragraphs: [
                    .prose([
                        BibleVerse(number: 16, text: "For God so loved the world."),
                        BibleVerse(number: 17, text: "For God sent not his Son."),
                    ]),
                ]),
            ]
        )
    }

    private static let searchHits: [BibleVerseMatch] = [
        BibleVerseMatch(bookId: "PHP", chapter: 4, verse: 6, text: "Be careful for nothing."),
    ]

    private func makeTool(
        books: [BibleBook]? = nil,
        hits: [BibleVerseMatch] = LookupBibleToolTests.searchHits,
        currentTranslation: String? = nil
    ) -> (tool: LookupBibleTool, searcher: RecordingSearcher) {
        let searcher = RecordingSearcher(hits: hits)
        let repository = StubPositionRepository(record: currentTranslation.map {
            BibleReadingPositionRecord(
                bookId: "JHN", chapterNumber: 3, translationId: $0,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        })
        let tool = LookupBibleTool(
            textLoader: StubBibleTextLoader(books: books ?? [johnBook]),
            searcher: searcher,
            positionRepository: repository
        )
        return (tool, searcher)
    }

    // MARK: - Action dispatch

    @Test("action 'read' fetches the named passage and stamps the result with the lookup id")
    func readDispatch() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("read"),
            "references": .array([
                .object(["book": .string("John"), "chapter": .int(3), "startVerse": .int(16)]),
            ]),
        ])
        #expect(result.isError == false)
        // The result carries the merged tool's id, not the delegate's old one.
        #expect(result.toolID == LookupBibleTool.toolID)
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    @Test("action 'search' returns ranked verses and stamps the result with the lookup id")
    func searchDispatch() async throws {
        let (tool, searcher) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("search"),
            "query": .string("anxiety"),
        ])
        #expect(result.isError == false)
        #expect(result.toolID == LookupBibleTool.toolID)
        #expect(result.content.contains("Philippians 4:6"))
        #expect(await searcher.lastMode == .any)
    }

    // MARK: - Action validation

    @Test("a missing action is a soft error that names both actions")
    func missingAction() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: ["query": .string("anxiety")])
        #expect(result.isError == true)
        #expect(result.toolID == LookupBibleTool.toolID)
        #expect(result.content.contains("action is required"))
    }

    @Test("an unknown action is a soft error")
    func unknownAction() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: ["action": .string("annotate")])
        #expect(result.isError == true)
        #expect(result.content.contains("Unknown action 'annotate'"))
    }

    // MARK: - Shared translation

    @Test("the shared translation applies to a read action")
    func sharedTranslationOnRead() async throws {
        let (tool, _) = makeTool(currentTranslation: "ASV")
        let result = try await tool.execute(input: [
            "action": .string("read"),
            "references": .array([
                .object(["book": .string("John"), "chapter": .int(3), "startVerse": .int(16)]),
            ]),
            "translation": .string("web"),
        ])
        #expect(result.content.hasPrefix("John 3:16 (WEB)"))
    }

    @Test("the shared translation applies to a search action")
    func sharedTranslationOnSearch() async throws {
        let (tool, searcher) = makeTool(currentTranslation: "ASV")
        _ = try await tool.execute(input: [
            "action": .string("search"),
            "query": .string("anxiety"),
            "translation": .string("web"),
        ])
        #expect(await searcher.lastTranslation == .web)
    }

    // MARK: - Descriptor

    @Test("the descriptor advertises the action discriminator and the search match enum")
    func descriptorSchema() {
        let params = LookupBibleTool.descriptor.parameters
        let action = params.first { $0.name == "action" }
        #expect(action?.isRequired == true)
        #expect(action?.enumValues == ["read", "search"])

        let match = params.first { $0.name == "match" }
        #expect(match?.isRequired == false)
        #expect(match?.enumValues == BibleSearchMatchMode.allCases.map(\.rawValue))

        // references is optional at the schema level — validity is gated per
        // action in the executor, not by the schema (no provider expresses a
        // discriminated union).
        #expect(params.first { $0.name == "references" }?.isRequired == false)

        // Every top-level parameter ships a compact variant for the compact tier.
        #expect(params.allSatisfy { $0.compactDescription != nil })
    }
}

// MARK: - Test doubles

/// A `BibleTextLoader` serving chapters from a fixed set of books; `nil` for any
/// other book id or absent chapter (mirroring the DB loader's missing-row case).
private struct StubBibleTextLoader: BibleTextLoader {
    let books: [BibleBook]
    func loadChapter(
        bookId: String, chapterNumber: Int, translation: BibleTranslation
    ) throws -> BibleChapter? {
        guard let book = books.first(where: { $0.id == bookId }) else { return nil }
        return book.chapter(chapterNumber)
    }
}

/// A `BibleTextSearching` that records the last call's arguments and returns a
/// fixed result set, so the routing test can assert the search path ran.
private actor RecordingSearcher: BibleTextSearching {
    let hits: [BibleVerseMatch]
    private(set) var lastTranslation: BibleTranslation?
    private(set) var lastMode: BibleSearchMatchMode?

    init(hits: [BibleVerseMatch]) { self.hits = hits }

    func search(
        query: String, translation: BibleTranslation, bookId: String?,
        mode: BibleSearchMatchMode, limit: Int
    ) async throws -> [BibleVerseMatch] {
        lastTranslation = translation
        lastMode = mode
        return hits
    }
}
