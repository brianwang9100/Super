import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `NoteBibleTool` — the create/edit/delete action dispatch, input
/// validation per action, stamping, and the artifact contract.
@Suite("NoteBibleTool")
struct NoteBibleToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTool(
        stamp: BibleNoteStamp = BibleNoteStamp(source: .assistant, modelId: "claude"),
        repository: SpyBibleNoteRepository = SpyBibleNoteRepository()
    ) -> (NoteBibleTool, SpyBibleNoteRepository) {
        let tool = NoteBibleTool(
            repository: repository,
            clock: FixedClock(t0),
            ids: DeterministicIDGenerator(prefix: "note-"),
            stampProvider: FakeNoteStampProvider(stamp: stamp)
        )
        return (tool, repository)
    }

    // MARK: - Create

    @Test("create inserts a verse note with stamped provenance and timestamps")
    func createVerseNote() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("verse"),
            "bookId": .string("JHN"),
            "chapterNumber": .int(3),
            "verseStart": .int(16),
            "verseEnd": .int(18),
            "body": .string("The hinge of the gospel."),
        ])
        #expect(result.isError == false)
        #expect(result.artifacts.map(\.id) == ["note-1"])
        #expect(result.artifacts.first?.type == "note")

        let inserted = await repo.inserted
        #expect(inserted.count == 1)
        let note = try #require(inserted.first)
        #expect(note.id == "note-1")
        #expect(note.target == .verse)
        #expect(note.bookId == "JHN")
        #expect(note.verseStart == 16)
        #expect(note.verseEnd == 18)
        #expect(note.body == "The hinge of the gospel.")
        #expect(note.source == .assistant)
        #expect(note.modelId == "claude")
        #expect(note.createdAt == t0)
        #expect(note.updatedAt == t0)
    }

    @Test("book-target create leaves chapter and verse columns nil")
    func createBookNote() async throws {
        let (tool, repo) = makeTool()
        _ = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("book"),
            "bookId": .string("JHN"),
            "body": .string("The signs gospel."),
        ])
        let note = try #require(await repo.inserted.first)
        #expect(note.target == .book)
        #expect(note.chapterNumber == nil)
        #expect(note.verseStart == nil)
        #expect(note.verseEnd == nil)
    }

    @Test("integer position params serialized as Double are coerced to Int")
    func doubleCoercedToInt() async throws {
        let (tool, repo) = makeTool()
        _ = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("verse"),
            "bookId": .string("JHN"),
            "chapterNumber": .double(3.0),
            "verseStart": .double(16.0),
            "verseEnd": .double(18.0),
            "body": .string("."),
        ])
        let note = try #require(await repo.inserted.first)
        #expect(note.chapterNumber == 3)
        #expect(note.verseStart == 16)
        #expect(note.verseEnd == 18)
    }

    // MARK: - Edit

    @Test("edit updates the note body by id")
    func editNote() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("edit"),
            "id": .string("abc"),
            "body": .string("Revised thought."),
        ])
        #expect(result.isError == false)
        #expect(result.artifacts.map(\.id) == ["abc"])
        let update = await repo.lastUpdate
        #expect(update?.id == "abc")
        #expect(update?.body == "Revised thought.")
        #expect(update?.updatedAt == t0)
        // Edit must not insert.
        #expect(await repo.inserted.isEmpty)
    }

    // MARK: - Delete

    @Test("delete removes the note by id")
    func deleteNote() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("delete"),
            "id": .string("xyz"),
        ])
        #expect(result.isError == false)
        #expect(result.artifacts.map(\.id) == ["xyz"])
        #expect(await repo.deleted == ["xyz"])
    }

    // MARK: - Validation rejections

    @Test("unknown action returns an error without writing")
    func unknownActionRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("frobnicate"),
            "id": .string("x"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("frobnicate"))
        #expect(await repo.inserted.isEmpty)
        #expect(await repo.lastUpdate == nil)
        #expect(await repo.deleted.isEmpty)
    }

    @Test("missing action rejects")
    func missingActionRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "body": .string("orphan"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("action"))
    }

    @Test("create with empty body rejects")
    func createEmptyBodyRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("verse"),
            "bookId": .string("JHN"),
            "chapterNumber": .int(3),
            "verseStart": .int(16),
            "verseEnd": .int(16),
            "body": .string("   "),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("body"))
        #expect(await repo.inserted.isEmpty)
    }

    @Test("create verse target without verseEnd rejects")
    func createVerseMissingVerseEndRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("verse"),
            "bookId": .string("JHN"),
            "chapterNumber": .int(3),
            "verseStart": .int(16),
            "body": .string("note"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("verseEnd"))
    }

    @Test("create verse target with inverted range rejects")
    func createInvertedRangeRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("verse"),
            "bookId": .string("JHN"),
            "chapterNumber": .int(3),
            "verseStart": .int(18),
            "verseEnd": .int(16),
            "body": .string("note"),
        ])
        #expect(result.isError == true)
    }

    /// `target` is the authoritative discriminator: a `book` create that
    /// carries stray chapter/verse fields is accepted and those fields are
    /// coerced to `nil` rather than rejected (matches `bible.annotate`).
    @Test("create book target coerces stray chapter/verse fields to nil")
    func createBookCoercesStrayPositionFields() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("book"),
            "bookId": .string("JHN"),
            "chapterNumber": .int(3),
            "verseStart": .int(16),
            "verseEnd": .int(18),
            "body": .string("note"),
        ])
        #expect(result.isError == false)
        let note = try #require(await repo.inserted.first)
        #expect(note.target == .book)
        #expect(note.chapterNumber == nil)
        #expect(note.verseStart == nil)
        #expect(note.verseEnd == nil)
    }

    /// A chapter create with a stray `verseStart` no longer errors — the verse
    /// fields are dropped, `chapterNumber` is preserved.
    @Test("create chapter target coerces stray verse fields to nil")
    func createChapterCoercesStrayVerseFields() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("chapter"),
            "bookId": .string("JHN"),
            "chapterNumber": .int(3),
            "verseStart": .int(16),
            "verseEnd": .int(18),
            "body": .string("note"),
        ])
        #expect(result.isError == false)
        let note = try #require(await repo.inserted.first)
        #expect(note.target == .chapter)
        #expect(note.chapterNumber == 3)
        #expect(note.verseStart == nil)
        #expect(note.verseEnd == nil)
    }

    /// Regression: a coerced chapter note must remain addressable by a
    /// chapter-target read (`verseStart IS NULL`) — i.e. it isn't orphaned by
    /// the stray verse fields the caller sent. Driven against the real GRDB
    /// repository so the `IS NULL` query is the production one. Mirrors the
    /// `AnnotateBibleTool` regression.
    @Test("coerced chapter note is found by a chapter-target read")
    func coercedChapterNoteIsAddressable() async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleNoteRepository(database: database)
        let tool = NoteBibleTool(
            repository: repository,
            clock: FixedClock(t0),
            ids: DeterministicIDGenerator(prefix: "note-"),
            stampProvider: FakeNoteStampProvider(
                stamp: BibleNoteStamp(source: .assistant, modelId: "claude")
            )
        )
        _ = try await tool.execute(input: [
            "action": .string("create"),
            "target": .string("chapter"),
            "bookId": .string("JHN"),
            "chapterNumber": .int(3),
            "verseStart": .int(16),
            "body": .string("Chapter note."),
        ])

        let notes = try await repository.list(
            target: .chapter, bookId: "JHN", chapterNumber: 3, verseStart: nil, verseEnd: nil
        )
        #expect(notes.count == 1)
        #expect(notes.first?.body == "Chapter note.")
    }

    @Test("edit without id rejects")
    func editMissingIdRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("edit"),
            "body": .string("revised"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("id"))
        #expect(await repo.lastUpdate == nil)
    }

    @Test("edit without body rejects")
    func editMissingBodyRejects() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("edit"),
            "id": .string("abc"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("body"))
    }

    @Test("delete without id rejects")
    func deleteMissingIdRejects() async throws {
        let (tool, repo) = makeTool()
        let result = try await tool.execute(input: [
            "action": .string("delete"),
        ])
        #expect(result.isError == true)
        #expect(result.content.contains("id"))
        #expect(await repo.deleted.isEmpty)
    }
}

/// Registration plumbing — the `bible.note` tool lands in a `ToolRegistry`
/// enabled, with its descriptor intact.
@Suite("NoteBibleTool registration")
struct NoteBibleToolRegistrationTests {
    @Test("registration adds bible.note to the registry, enabled")
    func registersEnabled() async throws {
        let registry = ToolRegistry()
        await registry.register(
            NoteBibleTool.registration(repository: SpyBibleNoteRepository())
        )
        let registrations = await registry.allRegistrations()
        let note = try #require(registrations.first { $0.tool.id == NoteBibleTool.toolID })
        #expect(note.isEnabled)
        #expect(note.tool.appletId == "bible")
        #expect(note.tool.category == .mutation)
    }
}

// MARK: - Doubles

/// Strict spy recording each write. Per the testability rules, methods the
/// exercised action shouldn't touch are still implemented (the protocol
/// requires them) but the assertions above pin which were used.
private actor SpyBibleNoteRepository: BibleNoteRepository {
    struct UpdateCall: Sendable {
        let id: String
        let body: String
        let updatedAt: Date
    }

    private(set) var inserted: [BibleNoteRecord] = []
    private(set) var lastUpdate: UpdateCall?
    private(set) var deleted: [String] = []

    func list(
        target: BibleNoteTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> [BibleNoteRecord] {
        // The tool path never reads — a hit here is a caller-side bug.
        fatalError("SpyBibleNoteRepository.list called — tool path should not read.")
    }

    func insert(_ note: BibleNoteRecord) async throws {
        inserted.append(note)
    }

    func update(id: String, body: String, updatedAt: Date) async throws {
        lastUpdate = UpdateCall(id: id, body: body, updatedAt: updatedAt)
    }

    func deleteOne(id: String) async throws {
        deleted.append(id)
    }
}

private struct FakeNoteStampProvider: BibleNoteStampProvider {
    let fixedStamp: BibleNoteStamp
    init(stamp: BibleNoteStamp) { self.fixedStamp = stamp }
    func stamp() -> BibleNoteStamp { fixedStamp }
}
