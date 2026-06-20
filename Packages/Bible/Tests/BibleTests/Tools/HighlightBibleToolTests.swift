import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `HighlightBibleTool` — the read/search/set/clear action dispatch,
/// per-action input validation, book-name resolution, range looping, and the
/// result text contract.
@Suite("HighlightBibleTool")
struct HighlightBibleToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTool(
        _ repository: SpyBibleHighlightRepository = SpyBibleHighlightRepository()
    ) -> (HighlightBibleTool, SpyBibleHighlightRepository) {
        let tool = HighlightBibleTool(
            repository: repository,
            clock: FixedClock(t0),
            catalog: .standard
        )
        return (tool, repository)
    }

    private func record(
        _ bookId: String, _ chapter: Int, _ verse: Int, _ color: BibleHighlightColor
    ) -> BibleHighlightRecord {
        BibleHighlightRecord(
            id: "\(bookId)-\(chapter)-\(verse)",
            bookId: bookId,
            chapterNumber: chapter,
            verseNumber: verse,
            colorId: color.rawValue,
            createdAt: t0,
            updatedAt: t0
        )
    }

    // MARK: - Set

    @Test("set highlights a single verse at the fixed clock time")
    func setSingleVerse() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("John"),
            "chapter": .int(3),
            "verseStart": .int(16),
            "color": .string("yellow"),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("John 3:16"))
        #expect(result.content.contains("yellow"))

        let sets = await repo.sets
        #expect(sets.count == 1)
        let call = try #require(sets.first)
        #expect(call.bookId == "JHN")
        #expect(call.chapterNumber == 3)
        #expect(call.verseNumber == 16)
        #expect(call.color == .yellow)
        #expect(call.at == t0)
        #expect(await repo.clears.isEmpty)
    }

    @Test("set loops every verse in a range")
    func setRangeLoops() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("John"),
            "chapter": .int(3),
            "verseStart": .int(16),
            "verseEnd": .int(18),
            "color": .string("green"),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("John 3:16-18"))
        let sets = await repo.sets
        #expect(sets.map(\.verseNumber) == [16, 17, 18])
        #expect(sets.allSatisfy { $0.color == .green && $0.at == t0 })
    }

    @Test("set resolves a 3-letter book code")
    func setResolvesCode() async throws {
        let (tool, repo) = makeTool()
        _ = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("JHN"),
            "chapter": .int(3),
            "verseStart": .int(16),
            "color": .string("blue"),
        ])
        #expect(await repo.sets.first?.bookId == "JHN")
    }

    @Test("set without color rejects")
    func setMissingColorRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("John"),
            "chapter": .int(3),
            "verseStart": .int(16),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("color"))
        #expect(await repo.sets.isEmpty)
    }

    @Test("set without a verse range rejects")
    func setMissingRangeRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("John"),
            "chapter": .int(3),
            "color": .string("yellow"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("verseStart"))
        #expect(await repo.sets.isEmpty)
    }

    @Test("set with an unknown color rejects")
    func setUnknownColorRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("John"),
            "chapter": .int(3),
            "verseStart": .int(16),
            "color": .string("turquoise"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("turquoise"))
        #expect(await repo.sets.isEmpty)
    }

    @Test("set with an unknown book rejects")
    func setUnknownBookRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("Hesitations"),
            "chapter": .int(1),
            "verseStart": .int(1),
            "color": .string("yellow"),
        ])
        #expect(result.isError == true)
        #expect(await repo.sets.isEmpty)
    }

    @Test("set with an out-of-range chapter rejects")
    func setChapterOutOfRangeRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("John"),
            "chapter": .int(99),
            "verseStart": .int(1),
            "color": .string("yellow"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("out of range"))
        #expect(await repo.sets.isEmpty)
    }

    @Test("chapter serialized as a Double is coerced to Int")
    func doubleChapterCoerced() async throws {
        let (tool, repo) = makeTool()
        _ = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("John"),
            "chapter": .double(3.0),
            "verseStart": .double(16.0),
            "color": .string("yellow"),
        ])
        #expect(await repo.sets.first?.chapterNumber == 3)
        #expect(await repo.sets.first?.verseNumber == 16)
    }

    @Test("set rejects an over-long verse range instead of looping a million writes")
    func setRejectsOverLongRange() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("John"),
            "chapter": .int(3),
            "verseStart": .int(1),
            "verseEnd": .int(999_999),
            "color": .string("yellow"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("spans"))
        // No writes attempted — the cap is enforced before the loop.
        #expect(await repo.sets.isEmpty)
    }

    @Test("set accepts a range right at the span cap")
    func setAcceptsRangeAtCap() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("set"),
            "book": .string("Psalms"),
            "chapter": .int(119),
            "verseStart": .int(1),
            "verseEnd": .int(HighlightBibleTool.maxVerseSpan),
            "color": .string("yellow"),
        ])
        #expect(result.isError == false)
        #expect(await repo.sets.count == HighlightBibleTool.maxVerseSpan)
    }

    // MARK: - Clear

    @Test("clear loops every verse in a range and runs without confirmation")
    func clearRangeLoops() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("clear"),
            "book": .string("John"),
            "chapter": .int(3),
            "verseStart": .int(16),
            "verseEnd": .int(17),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("John 3:16-17"))
        let clears = await repo.clears
        #expect(clears.map(\.verseNumber) == [16, 17])
        #expect(clears.allSatisfy { $0.bookId == "JHN" && $0.at == t0 })
        #expect(await repo.sets.isEmpty)
    }

    @Test("clear without a verse range rejects")
    func clearMissingRangeRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("clear"),
            "book": .string("John"),
            "chapter": .int(3),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("verseStart"))
        #expect(await repo.clears.isEmpty)
    }

    // MARK: - Read

    @Test("read reports each highlighted verse's colour within a range")
    func readRangeReportsColors() async throws {
        let repo = SpyBibleHighlightRepository(chapterRows: [
            record("JHN", 3, 16, .yellow),
            record("JHN", 3, 17, .green),
            record("JHN", 3, 30, .blue), // outside the requested range
        ])
        let (tool, _) = makeTool(repo)
        let result = try await tool.execute(input: [
            "action": .string("read"),
            "book": .string("John"),
            "chapter": .int(3),
            "verseStart": .int(16),
            "verseEnd": .int(18),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("John 3:16-18"))
        #expect(result.content.contains("yellow 16"))
        #expect(result.content.contains("green 17"))
        // Verse 30 is outside the requested range and must not appear.
        #expect(!result.content.contains("blue 30"))
        // The spy was asked for the chapter, not the per-verse colour map.
        #expect(await repo.chapterQueryCount == 1)
    }

    @Test("read with no range reads the whole chapter")
    func readWholeChapter() async throws {
        let repo = SpyBibleHighlightRepository(chapterRows: [
            record("JHN", 3, 16, .yellow),
            record("JHN", 3, 30, .blue),
        ])
        let (tool, _) = makeTool(repo)
        let result = try await tool.execute(input: [
            "action": .string("read"),
            "book": .string("John"),
            "chapter": .int(3),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("yellow 16"))
        #expect(result.content.contains("blue 30"))
    }

    @Test("read of an unhighlighted passage says so")
    func readEmpty() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("read"),
            "book": .string("John"),
            "chapter": .int(3),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("No highlights"))
        #expect(result.content.contains("John 3"))
    }

    // MARK: - Search

    @Test("search groups verses by colour across the whole bible in canonical order")
    func searchWholeBible() async throws {
        let repo = SpyBibleHighlightRepository(colorRows: [
            record("1PE", 2, 9, .yellow),
            record("ROM", 8, 28, .yellow),
        ])
        let (tool, _) = makeTool(repo)
        let result = try await tool.execute(input: [
            "action": .string("search"),
            "color": .string("yellow"),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("Romans 8:28"))
        #expect(result.content.contains("1 Peter 2:9"))
        // Romans (canonical #45) precedes 1 Peter (#60).
        let romans = try #require(result.content.range(of: "Romans 8:28"))
        let peter = try #require(result.content.range(of: "1 Peter 2:9"))
        #expect(romans.lowerBound < peter.lowerBound)
        // Whole-bible search passes no book scope.
        #expect(await repo.lastColorQuery?.bookId == nil)
        #expect(await repo.lastColorQuery?.color == .yellow)
    }

    @Test("search narrows to a book when one is named")
    func searchScopedToBook() async throws {
        let repo = SpyBibleHighlightRepository(colorRows: [record("ROM", 8, 28, .yellow)])
        let (tool, _) = makeTool(repo)
        let result = try await tool.execute(input: [
            "action": .string("search"),
            "color": .string("yellow"),
            "book": .string("Romans"),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("in Romans"))
        #expect(await repo.lastColorQuery?.bookId == "ROM")
    }

    @Test("search with no matches says so")
    func searchEmpty() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("search"),
            "color": .string("pink"),
        ])
        #expect(result.isError == false)
        #expect(result.content.contains("No verses highlighted pink"))
    }

    @Test("search without a color rejects")
    func searchMissingColorRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("search"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("color"))
    }

    @Test("search with an unknown color rejects")
    func searchUnknownColorRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("search"),
            "color": .string("crimson"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("crimson"))
    }

    // MARK: - Dispatch

    @Test("unknown action rejects without writing")
    func unknownActionRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("frobnicate"),
            "book": .string("John"),
            "chapter": .int(3),
            "verseStart": .int(16),
            "color": .string("yellow"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("frobnicate"))
        #expect(await repo.sets.isEmpty)
        #expect(await repo.clears.isEmpty)
    }

    @Test("missing action rejects")
    func missingActionRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "book": .string("John"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("action"))
    }
}

/// Registration plumbing — the `bible.highlight` tool lands in a `ToolRegistry`
/// enabled, with its descriptor intact.
@Suite("HighlightBibleTool registration")
struct HighlightBibleToolRegistrationTests {
    @Test("registration adds bible.highlight to the registry, enabled")
    func registersEnabled() async throws {
        let registry = ToolRegistry()
        await registry.register(
            HighlightBibleTool.registration(repository: SpyBibleHighlightRepository())
        )
        let registrations = await registry.allRegistrations()
        let highlight = try #require(registrations.first { $0.tool.id == HighlightBibleTool.toolID })
        #expect(highlight.isEnabled)
        #expect(highlight.tool.appletId == "bible")
        #expect(highlight.tool.category == .mutation)
    }
}

// MARK: - Doubles

/// Strict spy recording each write and the read queries. Scripted return values
/// are passed at init; `activeHighlightColors` `fatalError`s because the tool
/// path never uses the per-verse colour map (it reads whole chapters).
private actor SpyBibleHighlightRepository: BibleHighlightRepository {
    struct SetCall: Sendable {
        let bookId: String
        let chapterNumber: Int
        let verseNumber: Int
        let color: BibleHighlightColor
        let at: Date
    }
    struct ClearCall: Sendable {
        let bookId: String
        let chapterNumber: Int
        let verseNumber: Int
        let at: Date
    }
    struct ColorQuery: Sendable {
        let color: BibleHighlightColor
        let bookId: String?
    }

    private(set) var sets: [SetCall] = []
    private(set) var clears: [ClearCall] = []
    private(set) var chapterQueryCount = 0
    private(set) var lastColorQuery: ColorQuery?

    private let chapterRows: [BibleHighlightRecord]
    private let colorRows: [BibleHighlightRecord]

    init(
        chapterRows: [BibleHighlightRecord] = [],
        colorRows: [BibleHighlightRecord] = []
    ) {
        self.chapterRows = chapterRows
        self.colorRows = colorRows
    }

    func setHighlight(
        bookId: String, chapterNumber: Int, verseNumber: Int,
        color: BibleHighlightColor, at now: Date
    ) async throws {
        sets.append(SetCall(
            bookId: bookId, chapterNumber: chapterNumber, verseNumber: verseNumber, color: color, at: now
        ))
    }

    func clearHighlight(
        bookId: String, chapterNumber: Int, verseNumber: Int, at now: Date
    ) async throws {
        clears.append(ClearCall(
            bookId: bookId, chapterNumber: chapterNumber, verseNumber: verseNumber, at: now
        ))
    }

    func activeHighlightColors(
        bookId: String, chapterNumber: Int, verseNumbers: [Int]
    ) async throws -> [Int: BibleHighlightColor] {
        fatalError("SpyBibleHighlightRepository.activeHighlightColors called — tool path reads whole chapters.")
    }

    func activeHighlights(
        bookId: String, chapterNumber: Int
    ) async throws -> [BibleHighlightRecord] {
        chapterQueryCount += 1
        return chapterRows
    }

    func activeHighlights(
        color: BibleHighlightColor, bookId: String?
    ) async throws -> [BibleHighlightRecord] {
        lastColorQuery = ColorQuery(color: color, bookId: bookId)
        return colorRows
    }
}
