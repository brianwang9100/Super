import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `AnnotateBibleTool` — input validation, stamping, the
/// single-summary write, and the source/modelId derivation contract.
@Suite("AnnotateBibleTool")
struct AnnotateBibleToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A short but plausible markdown summary for happy-path inputs.
    private let sampleSummary = "### Context\n\n**Paul** writes to a mixed Jew/Gentile church."

    private func makeTool(
        stamp: BibleAnnotationStamp = BibleAnnotationStamp(source: .user, modelId: "afm-3.0"),
        repository: SpyBibleAnnotationRepository = SpyBibleAnnotationRepository()
    ) -> (AnnotateBibleTool, SpyBibleAnnotationRepository) {
        let tool = AnnotateBibleTool(
            repository: repository,
            stampProvider: FakeStampProvider(stamp: stamp),
            clock: FixedClock(t0),
            ids: DeterministicIDGenerator(prefix: "anno-")
        )
        return (tool, repository)
    }

    // MARK: - Descriptor schema

    /// The single-summary redesign: the descriptor takes one required
    /// `summary` string and no longer declares the multi-card `entries`
    /// array (whose Gemini `valueSchema` requirement died with it).
    @Test("descriptor declares a required summary string and no entries array")
    func descriptorDeclaresSummaryNotEntries() {
        let parameters = AnnotateBibleTool.descriptor.parameters
        #expect(parameters.first { $0.name == "entries" } == nil)
        let summary = parameters.first { $0.name == "summary" }
        #expect(summary?.type == .string)
        #expect(summary?.isRequired == true)
    }

    // MARK: - Descriptor prompt steering

    /// Regression: the descriptor must steer the model to reserve
    /// `bible.annotate` for explicit annotate requests (it writes a
    /// persistent summary) rather than firing on plain context/explain
    /// questions. Asserts the load-bearing steer words, not whole
    /// sentences, so wording can be polished without churning the test.
    @Test("descriptor reserves the tool for explicit annotate requests")
    func descriptorSteersExplicitAnnotateOnly() {
        let description = AnnotateBibleTool.descriptor.description.lowercased()
        #expect(description.contains("only when the user explicitly asks to annotate"))
        #expect(description.contains("answer in the conversation"))
        // Free-text note requests belong to `bible.note`, not annotate.
        #expect(description.contains("bible.note"))
    }

    /// Regression: a cited cross-reference is only for a genuine
    /// intertextual link (quotation / allusion / citation), never a merely
    /// thematically similar verse. Guards against the prior
    /// "illuminating"-only wording that produced junk "see this similar
    /// verse" citations.
    @Test("descriptor restricts citations to genuine cross-references")
    func descriptorRestrictsCrossReferences() {
        let description = AnnotateBibleTool.descriptor.description.lowercased()
        #expect(description.contains("cross-reference"))
        #expect(description.contains("alludes to"))
        #expect(description.contains("thematically"))
    }

    // MARK: - Happy path

    @Test("verse-target call writes one row with the parsed summary and stamped fields")
    func versePathWritesOneStampedRecord() async throws {
        let (tool, repo) = makeTool()
        let input: [String: JSONValue] = [
            "target": .string("verse"),
            "bookId": .string("ROM"),
            "chapterNumber": .int(8),
            "verseStart": .int(28),
            "verseEnd": .int(30),
            "summary": .string(sampleSummary),
        ]

        let result = try await tool.execute(input: input)
        #expect(result.isError == false)
        #expect(result.content == "Wrote an annotation for the target.")
        // Exactly one artifact — the single summary row just written.
        #expect(result.artifacts.count == 1)
        #expect(result.artifacts.first?.type == "annotation")
        #expect(result.artifacts.first?.id == "anno-1")

        let call = await repo.lastCall
        let inserts = call?.inserts ?? []
        #expect(inserts.count == 1)
        #expect(inserts[0].id == "anno-1")
        #expect(inserts[0].target == .verse)
        #expect(inserts[0].bookId == "ROM")
        #expect(inserts[0].chapterNumber == 8)
        #expect(inserts[0].verseStart == 28)
        #expect(inserts[0].verseEnd == 30)
        #expect(inserts[0].summary == sampleSummary)
        #expect(inserts[0].source == .user)
        #expect(inserts[0].modelId == "afm-3.0")
        #expect(inserts[0].createdAt == t0)
    }

    @Test("book-target call has no chapter or verse columns set")
    func bookPathLeavesPositionNil() async throws {
        let (tool, repo) = makeTool()
        let input: [String: JSONValue] = [
            "target": .string("book"),
            "bookId": .string("ROM"),
            "summary": .string("Long, systematic letter."),
        ]

        _ = try await tool.execute(input: input)
        let call = await repo.lastCall
        let inserts = call?.inserts ?? []
        #expect(inserts.count == 1)
        #expect(inserts[0].chapterNumber == nil)
        #expect(inserts[0].verseStart == nil)
        #expect(inserts[0].verseEnd == nil)
    }

    @Test("source derives from the injected stamp provider")
    func sourceDerivedFromProvider() async throws {
        let bulkRepo = SpyBibleAnnotationRepository()
        let (tool, _) = makeTool(
            stamp: BibleAnnotationStamp(source: .userBulk, modelId: "claude"),
            repository: bulkRepo
        )
        let input: [String: JSONValue] = [
            "target": .string("book"),
            "bookId": .string("ROM"),
            "summary": .string("Overview."),
        ]
        _ = try await tool.execute(input: input)
        let inserts = await bulkRepo.lastCall?.inserts ?? []
        #expect(inserts.first?.source == .userBulk)
        #expect(inserts.first?.modelId == "claude")
    }

    @Test("integer parameters serialized as Double are coerced to Int")
    func doubleCoercedToInt() async throws {
        let (tool, repo) = makeTool()
        let input: [String: JSONValue] = [
            "target": .string("verse"),
            "bookId": .string("ROM"),
            "chapterNumber": .double(8.0),
            "verseStart": .double(28.0),
            "verseEnd": .double(30.0),
            "summary": .string("."),
        ]
        _ = try await tool.execute(input: input)
        let call = await repo.lastCall
        #expect(call?.chapterNumber == 8)
        #expect(call?.verseStart == 28)
        #expect(call?.verseEnd == 30)
    }

    // MARK: - Replace semantics

    /// Calling the tool twice for the same target converges on one row —
    /// the write goes through `repository.replace`, which clears the
    /// target's prior rows before inserting. Driven against the real GRDB
    /// repository so the clearing is the production query, not a spy echo.
    @Test("a second call for the same target replaces the prior row")
    func secondCallReplacesPriorRow() async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleAnnotationRepository(database: database)
        let tool = AnnotateBibleTool(
            repository: repository,
            stampProvider: FakeStampProvider(
                stamp: BibleAnnotationStamp(source: .user, modelId: "afm-3.0")
            ),
            clock: FixedClock(t0),
            ids: DeterministicIDGenerator(prefix: "anno-")
        )
        func input(summary: String) -> [String: JSONValue] {
            [
                "target": .string("chapter"),
                "bookId": .string("ROM"),
                "chapterNumber": .int(8),
                "summary": .string(summary),
            ]
        }

        _ = try await tool.execute(input: input(summary: "First pass."))
        _ = try await tool.execute(input: input(summary: "Second pass."))

        let rows = try await repository.list(
            target: .chapter, bookId: "ROM", chapterNumber: 8, verseStart: nil, verseEnd: nil
        )
        #expect(rows.count == 1)
        #expect(rows.first?.summary == "Second pass.")
        #expect(rows.first?.id == "anno-2")
    }

    // MARK: - Validation rejections

    @Test("missing target returns an error result without writing")
    func missingTargetRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "bookId": .string("ROM"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("target"))
        let call = await repo.lastCall
        #expect(call == nil)
    }

    @Test("verse target without verseEnd rejects")
    func verseMissingVerseEndRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "target": .string("verse"),
            "bookId": .string("ROM"),
            "chapterNumber": .int(8),
            "verseStart": .int(28),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("verseEnd"))
        let call = await repo.lastCall
        #expect(call == nil)
    }

    @Test("verse target with inverted range rejects")
    func verseInvertedRangeRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "target": .string("verse"),
            "bookId": .string("ROM"),
            "chapterNumber": .int(8),
            "verseStart": .int(30),
            "verseEnd": .int(28),
        ])
        #expect(result.isError == true)
    }

    @Test("book target that includes a chapter rejects")
    func bookWithChapterRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "target": .string("book"),
            "bookId": .string("ROM"),
            "chapterNumber": .int(8),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("book"))
    }

    @Test("missing summary rejects with the exact remediation message")
    func missingSummaryRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "target": .string("chapter"),
            "bookId": .string("ROM"),
            "chapterNumber": .int(8),
        ])
        #expect(result.isError == true)
        #expect(result.content == "summary is required and must be a string.")
        let call = await repo.lastCall
        #expect(call == nil)
    }

    @Test("whitespace-only summary rejects without writing")
    func whitespaceSummaryRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "target": .string("chapter"),
            "bookId": .string("ROM"),
            "chapterNumber": .int(8),
            "summary": .string("  \n\t "),
        ])
        #expect(result.isError == true)
        #expect(result.content == "summary is empty. Pass the markdown study summary text.")
        let call = await repo.lastCall
        #expect(call == nil)
    }
}

// MARK: - Doubles

/// Strict spy that records the last `replace` call and asserts repository
/// methods aren't used outside the contract `AnnotateBibleTool` exercises.
private actor SpyBibleAnnotationRepository: BibleAnnotationRepository {
    struct ReplaceCall: Sendable {
        let target: BibleAnnotationTarget
        let bookId: String
        let chapterNumber: Int?
        let verseStart: Int?
        let verseEnd: Int?
        let inserts: [BibleAnnotationRecord]
    }

    private(set) var lastCall: ReplaceCall?

    func list(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> [BibleAnnotationRecord] {
        // Strict double: the tool path never reads, so a hit here is a
        // caller-side bug. Fail loudly with a stack trace that points at
        // the misconfigured test rather than returning an empty array
        // and letting downstream assertions accidentally pass.
        fatalError("SpyBibleAnnotationRepository.list called — tool path should not read.")
    }

    func replace(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?,
        inserting records: [BibleAnnotationRecord]
    ) async throws {
        lastCall = ReplaceCall(
            target: target,
            bookId: bookId,
            chapterNumber: chapterNumber,
            verseStart: verseStart,
            verseEnd: verseEnd,
            inserts: records
        )
    }

    func hasAnnotation(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> Bool {
        fatalError("SpyBibleAnnotationRepository.hasAnnotation called — tool path should not read.")
    }

    func hasVerseAnnotations(bookId: String, chapterNumber: Int) async throws -> Bool {
        fatalError("SpyBibleAnnotationRepository.hasVerseAnnotations called — tool path should not read.")
    }

    func deleteOne(id: String) async throws {
        fatalError("SpyBibleAnnotationRepository.deleteOne called — tool path should not delete.")
    }

    func deleteAll() async throws {
        fatalError("SpyBibleAnnotationRepository.deleteAll called — tool path should not delete.")
    }
}

private struct FakeStampProvider: BibleAnnotationStampProvider {
    let fixedStamp: BibleAnnotationStamp
    init(stamp: BibleAnnotationStamp) { self.fixedStamp = stamp }
    func stamp() async -> BibleAnnotationStamp { fixedStamp }
}
