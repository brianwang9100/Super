import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `AnnotateBibleTool` — input validation, stamping, ordered
/// inserts, and the source/modelId derivation contract.
@Suite("AnnotateBibleTool")
struct AnnotateBibleToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTool(
        stamp: BibleAnnotationStamp = BibleAnnotationStamp(source: .user, modelId: "afm-3.0"),
        repository: SpyBibleAnnotationRepository = SpyBibleAnnotationRepository()
    ) -> (AnnotateBibleTool, SpyBibleAnnotationRepository) {
        let tool = AnnotateBibleTool(
            repository: repository,
            clock: FixedClock(t0),
            ids: DeterministicIDGenerator(prefix: "anno-"),
            stampProvider: FakeStampProvider(stamp: stamp)
        )
        return (tool, repository)
    }

    // MARK: - Happy path

    @Test("verse-target call inserts records in entry order with stamped fields")
    func versePathInsertsOrderedStampedRecords() async throws {
        let (tool, repo) = makeTool()
        let input: [String: JSONValue] = [
            "target": .string("verse"),
            "bookId": .string("ROM"),
            "chapterNumber": .int(8),
            "verseStart": .int(28),
            "verseEnd": .int(30),
            "entries": .array([
                .object([
                    "kind": .string("text"),
                    "title": .string("Author"),
                    "body": .string("Paul, writing from Rome."),
                ]),
                .object([
                    "kind": .string("reference"),
                    "title": .string("See also"),
                    "body": .string("Heb 4:15"),
                ]),
            ]),
        ]

        let result = try await tool.execute(input: input)
        #expect(result.isError == false)
        #expect(result.artifacts.count == 2)
        #expect(result.artifacts.map(\.id) == ["anno-1", "anno-2"])

        let call = await repo.lastCall
        let inserts = call?.inserts ?? []
        #expect(inserts.count == 2)
        #expect(inserts[0].id == "anno-1")
        #expect(inserts[0].kind == .text)
        #expect(inserts[0].title == "Author")
        #expect(inserts[0].source == .user)
        #expect(inserts[0].modelId == "afm-3.0")
        #expect(inserts[0].createdAt == t0)
        #expect(inserts[1].kind == .reference)
        #expect(inserts[1].body == "Heb 4:15")
    }

    @Test("book-target call has no chapter or verse columns set")
    func bookPathLeavesPositionNil() async throws {
        let (tool, repo) = makeTool()
        let input: [String: JSONValue] = [
            "target": .string("book"),
            "bookId": .string("ROM"),
            "entries": .array([
                .object([
                    "kind": .string("text"),
                    "title": .string("Prologue"),
                    "body": .string("Long, systematic letter."),
                ]),
            ]),
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
            "entries": .array([
                .object([
                    "kind": .string("text"),
                    "title": .string("T"),
                    "body": .string("."),
                ]),
            ]),
        ]
        _ = try await tool.execute(input: input)
        let inserts = await bulkRepo.lastCall?.inserts ?? []
        #expect(inserts.first?.source == .userBulk)
        #expect(inserts.first?.modelId == "claude")
    }

    @Test("empty entries array clears the target group via replace")
    func emptyEntriesClears() async throws {
        let (tool, repo) = makeTool()
        let input: [String: JSONValue] = [
            "target": .string("chapter"),
            "bookId": .string("ROM"),
            "chapterNumber": .int(8),
            "entries": .array([]),
        ]
        let result = try await tool.execute(input: input)
        #expect(result.isError == false)
        let call = await repo.lastCall
        #expect(call?.inserts.isEmpty == true)
        #expect(call?.target == .chapter)
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
            "entries": .array([
                .object([
                    "kind": .string("text"),
                    "title": .string("T"),
                    "body": .string("."),
                ]),
            ]),
        ]
        _ = try await tool.execute(input: input)
        let call = await repo.lastCall
        #expect(call?.chapterNumber == 8)
        #expect(call?.verseStart == 28)
        #expect(call?.verseEnd == 30)
    }

    // MARK: - Validation rejections

    @Test("missing target returns an error result without writing")
    func missingTargetRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "bookId": .string("ROM"),
            "entries": .array([]),
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
            "entries": .array([]),
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
            "entries": .array([]),
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
            "entries": .array([]),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("book"))
    }

    @Test("entry missing kind rejects")
    func entryMissingKindRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "target": .string("book"),
            "bookId": .string("ROM"),
            "entries": .array([
                .object([
                    "title": .string("T"),
                    "body": .string("."),
                ]),
            ]),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("kind"))
    }

    @Test("entry with unknown kind rejects")
    func entryUnknownKindRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "target": .string("book"),
            "bookId": .string("ROM"),
            "entries": .array([
                .object([
                    "kind": .string("audio"),
                    "title": .string("T"),
                    "body": .string("."),
                ]),
            ]),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("audio"))
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

    func deleteOne(id: String) async throws {
        fatalError("SpyBibleAnnotationRepository.deleteOne called — tool path should not delete.")
    }
}

private struct FakeStampProvider: BibleAnnotationStampProvider {
    let fixedStamp: BibleAnnotationStamp
    init(stamp: BibleAnnotationStamp) { self.fixedStamp = stamp }
    func stamp() async -> BibleAnnotationStamp { fixedStamp }
}
