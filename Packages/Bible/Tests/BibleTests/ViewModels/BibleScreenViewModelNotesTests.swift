import Core
import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for the note surface on `BibleScreenViewModel`:
///
/// - list / compose presentation (`presentNoteList`, `composeNote`,
///   `composeNoteForSelection`, `dismissNoteList`)
/// - per-row CRUD (`createNote`, `updateNote`, `deleteNote`) driving the
///   injected repository, with trimming, blank-body guards, and the
///   failure toast
/// - `citationLabel(for:)` formatting for note specs
///
/// Note-write tests drain the chained write task via
/// `_waitForPendingNoteWrite()` before asserting, so a captured-state read
/// never races the task that mutates it (AGENTS.md §2).
@Suite("BibleScreenViewModel notes")
@MainActor
struct BibleScreenViewModelNotesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Strict in-memory note-repository double capturing each write. An
    /// actor so the VM's `@Sendable` write closures reach it across the
    /// concurrency boundary; `list` traps because the VM never reads through
    /// the repository (reads are the list sheet's `@Query`).
    private actor SpyNoteRepository: BibleNoteRepository {
        struct UpdateCall: Sendable {
            let id: String
            let body: String
            let updatedAt: Date
        }
        private(set) var inserted: [BibleNoteRecord] = []
        private(set) var updates: [UpdateCall] = []
        private(set) var deleted: [String] = []

        func list(
            target: BibleNoteTarget, bookId: String, chapterNumber: Int?,
            verseStart: Int?, verseEnd: Int?
        ) async throws -> [BibleNoteRecord] {
            fatalError("SpyNoteRepository.list called — the VM never reads through the repository.")
        }
        func insert(_ note: BibleNoteRecord) async throws { inserted.append(note) }
        func update(id: String, body: String, updatedAt: Date) async throws {
            updates.append(UpdateCall(id: id, body: body, updatedAt: updatedAt))
        }
        func deleteOne(id: String) async throws { deleted.append(id) }
    }

    /// A note repository whose every write throws — drives the failure-toast
    /// path. `Equatable`-free sentinel error; the message text is what matters.
    private struct WriteFailed: Error {}
    private actor FailingNoteRepository: BibleNoteRepository {
        func list(
            target: BibleNoteTarget, bookId: String, chapterNumber: Int?,
            verseStart: Int?, verseEnd: Int?
        ) async throws -> [BibleNoteRecord] { [] }
        func insert(_ note: BibleNoteRecord) async throws { throw WriteFailed() }
        func update(id: String, body: String, updatedAt: Date) async throws { throw WriteFailed() }
        func deleteOne(id: String) async throws { throw WriteFailed() }
    }

    private func makeViewModel(
        noteRepository: (any BibleNoteRepository)? = nil,
        at position: BiblePosition = BiblePosition(bookId: "ROM", chapterNumber: 8)
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            noteRepository: noteRepository,
            clock: FixedClock(now),
            idGenerator: DeterministicIDGenerator(),
            initialPosition: position,
            narration: NarrationController(service: FakeNarrationService())
        )
    }

    // MARK: - Presentation

    @Test("presentNoteList opens the list without auto-composing")
    func presentOpensList() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let spec = BibleNoteTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        viewModel.presentNoteList(for: spec)
        #expect(viewModel.presentedNoteList?.spec == spec)
        #expect(viewModel.presentedNoteList?.autoCompose == false)
    }

    @Test("composeNote opens the list already composing")
    func composeOpensListComposing() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let spec = BibleNoteTargetSpec.book(bookId: "ROM")
        viewModel.composeNote(for: spec)
        #expect(viewModel.presentedNoteList?.spec == spec)
        #expect(viewModel.presentedNoteList?.autoCompose == true)
    }

    @Test("dismissNoteList clears the presentation")
    func dismissClearsList() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentNoteList(for: .chapter(bookId: "ROM", chapterNumber: 8))
        viewModel.dismissNoteList()
        #expect(viewModel.presentedNoteList == nil)
    }

    @Test("composeNoteForSelection targets the selection's bounding range and clears it")
    func composeForSelectionUsesBoundingRange() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        // A gapped selection (16, 18) collapses to one note on 16–18.
        viewModel.toggleVerse(18)
        viewModel.toggleVerse(16)
        viewModel.composeNoteForSelection()
        #expect(viewModel.presentedNoteList?.spec
            == .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 16, verseEnd: 18))
        #expect(viewModel.presentedNoteList?.autoCompose == true)
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("composeNoteForSelection is a no-op with nothing selected")
    func composeForSelectionNoSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.composeNoteForSelection()
        #expect(viewModel.presentedNoteList == nil)
    }

    // MARK: - CRUD

    @Test("createNote inserts a trimmed user note with the spec's position")
    func createInsertsUserNote() async throws {
        let spy = SpyNoteRepository()
        let viewModel = makeViewModel(noteRepository: spy)
        await viewModel.load()
        let spec = BibleNoteTargetSpec.verseRange(
            bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
        )
        viewModel.createNote(target: spec, body: "  Hinge of the gospel.  ")
        await viewModel._waitForPendingNoteWrite()

        let inserted = await spy.inserted
        #expect(inserted.count == 1)
        let note = try #require(inserted.first)
        #expect(note.target == .verse)
        #expect(note.bookId == "ROM")
        #expect(note.chapterNumber == 8)
        #expect(note.verseStart == 28)
        #expect(note.verseEnd == 30)
        #expect(note.body == "Hinge of the gospel.")
        #expect(note.source == .user)
        #expect(note.modelId == nil)
        #expect(note.createdAt == now)
        #expect(note.updatedAt == now)
    }

    @Test("createNote drops a blank body")
    func createDropsBlankBody() async {
        let spy = SpyNoteRepository()
        let viewModel = makeViewModel(noteRepository: spy)
        await viewModel.load()
        viewModel.createNote(target: .book(bookId: "ROM"), body: "   \n  ")
        await viewModel._waitForPendingNoteWrite()
        let inserted = await spy.inserted
        #expect(inserted.isEmpty)
    }

    @Test("updateNote replaces the body with the trimmed value and a fresh updatedAt")
    func updateReplacesBody() async throws {
        let spy = SpyNoteRepository()
        let viewModel = makeViewModel(noteRepository: spy)
        await viewModel.load()
        viewModel.updateNote(id: "note-1", body: "  revised  ")
        await viewModel._waitForPendingNoteWrite()
        let updates = await spy.updates
        #expect(updates.count == 1)
        let call = try #require(updates.first)
        #expect(call.id == "note-1")
        #expect(call.body == "revised")
        #expect(call.updatedAt == now)
    }

    @Test("deleteNote removes the note by id")
    func deleteRemovesNote() async {
        let spy = SpyNoteRepository()
        let viewModel = makeViewModel(noteRepository: spy)
        await viewModel.load()
        viewModel.deleteNote(id: "note-1")
        await viewModel._waitForPendingNoteWrite()
        let deleted = await spy.deleted
        #expect(deleted == ["note-1"])
    }

    @Test("a failed write raises a toast")
    func failedWriteToasts() async {
        let viewModel = makeViewModel(noteRepository: FailingNoteRepository())
        await viewModel.load()
        viewModel.createNote(target: .book(bookId: "ROM"), body: "x")
        await viewModel._waitForPendingNoteWrite()
        #expect(viewModel.toast == "Couldn't save the note.")
    }

    @Test("CRUD with no repository is a silent no-op")
    func noRepositoryNoOp() async {
        let viewModel = makeViewModel(noteRepository: nil)
        await viewModel.load()
        viewModel.createNote(target: .book(bookId: "ROM"), body: "x")
        await viewModel._waitForPendingNoteWrite()
        #expect(viewModel.toast == nil)
    }

    // MARK: - Reactive bridge (VM write → reader's @Query feed)

    @Test("a note created through the view model is visible through ChapterNotesRequest.fetch")
    func createIsObservableThroughReaderQuery() async throws {
        // The integration the reader relies on: the VM's create path lands a
        // row in the same table the chapter reader's `ChapterNotesRequest`
        // `@Query` observes, so the trailing note glyph appears without the
        // reader reloading. Uses the real GRDB repository + an in-memory DB
        // rather than a spy, since the point is the round-trip.
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleNoteRepository(database: database)
        let viewModel = makeViewModel(
            noteRepository: repository,
            at: BiblePosition(bookId: "JHN", chapterNumber: 3)
        )
        await viewModel.load()

        func chapterNoteCount() throws -> Int {
            try database.queue.read { db in
                try ChapterNotesRequest(bookId: "JHN", chapterNumber: 3).fetch(db).count
            }
        }
        #expect(try chapterNoteCount() == 0)

        viewModel.createNote(
            target: .verseRange(bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 18),
            body: "Monogenēs."
        )
        await viewModel._waitForPendingNoteWrite()

        #expect(try chapterNoteCount() == 1)
    }

    // MARK: - Citation label

    @Test("citationLabel for a note book spec uses the display name")
    func citationBook() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.citationLabel(for: BibleNoteTargetSpec.book(bookId: "ROM")) == "Romans")
    }

    @Test("citationLabel for a note chapter spec joins book and chapter")
    func citationChapter() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.citationLabel(for: BibleNoteTargetSpec.chapter(bookId: "ROM", chapterNumber: 8))
            == "Romans 8")
    }

    @Test("citationLabel for a note range uses a dash; a single verse omits it")
    func citationRange() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.citationLabel(
            for: BibleNoteTargetSpec.verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        ) == "Romans 8:28-30")
        #expect(viewModel.citationLabel(
            for: BibleNoteTargetSpec.verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 28)
        ) == "Romans 8:28")
    }
}
