import Core
import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for the bookmark surface on `BibleScreenViewModel`:
///
/// - sheet presentation (`presentBookmarkSheet`, `dismissBookmarkSheet`),
///   including the citation capture and the selection clear that prevents
///   the scrim-less action sheet racing the native bookmark sheet
/// - `toggleBookmark(color:)` driving the injected repository with the
///   *presented* chapter's coordinates, with the failure toast
///
/// Bookmark-write tests drain the chained write task via
/// `_waitForPendingBookmarkWrite()` before asserting, so a captured-state
/// read never races the task that mutates it (AGENTS.md §2).
@Suite("BibleScreenViewModel bookmarks")
@MainActor
struct BibleScreenViewModelBookmarksTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Strict bookmark-repository double capturing each toggle. An actor so
    /// the VM's `@Sendable` write closure reaches it across the concurrency
    /// boundary; `allBookmarks` traps because the VM never reads through the
    /// repository (reads are the sheet's `@Query`).
    private actor SpyBookmarkRepository: BibleBookmarkRepository {
        struct ToggleCall: Sendable, Equatable {
            let color: BibleBookmarkColor
            let bookId: String
            let chapterNumber: Int
            let at: Date
        }
        private(set) var toggles: [ToggleCall] = []

        func toggle(
            color: BibleBookmarkColor, bookId: String, chapterNumber: Int, at now: Date
        ) async throws {
            toggles.append(ToggleCall(color: color, bookId: bookId, chapterNumber: chapterNumber, at: now))
        }
        func allBookmarks() async throws -> [BibleBookmarkRecord] {
            fatalError("SpyBookmarkRepository.allBookmarks called — the VM never reads through the repository.")
        }
    }

    /// A bookmark repository whose toggle always throws — drives the
    /// failure-toast path.
    private struct WriteFailed: Error {}
    private actor FailingBookmarkRepository: BibleBookmarkRepository {
        func toggle(
            color: BibleBookmarkColor, bookId: String, chapterNumber: Int, at now: Date
        ) async throws { throw WriteFailed() }
        func allBookmarks() async throws -> [BibleBookmarkRecord] { [] }
    }

    private func makeViewModel(
        bookmarkRepository: (any BibleBookmarkRepository)? = nil,
        at position: BiblePosition = BiblePosition(bookId: "ROM", chapterNumber: 8)
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            bookmarkRepository: bookmarkRepository,
            clock: FixedClock(now),
            idGenerator: DeterministicIDGenerator(),
            initialPosition: position,
            narration: NarrationController(service: FakeNarrationService())
        )
    }

    // MARK: - Presentation

    @Test("presentBookmarkSheet captures the current chapter and its citation")
    func presentCapturesPositionAndCitation() {
        let viewModel = makeViewModel()
        viewModel.presentBookmarkSheet()
        #expect(viewModel.presentedBookmarkSheet?.bookId == "ROM")
        #expect(viewModel.presentedBookmarkSheet?.chapterNumber == 8)
        #expect(viewModel.presentedBookmarkSheet?.citation == "Romans 8")
    }

    @Test("presentBookmarkSheet clears any verse selection first")
    func presentClearsSelection() {
        let viewModel = makeViewModel()
        viewModel.toggleVerse(3)
        #expect(!viewModel.selectedVerses.isEmpty)
        viewModel.presentBookmarkSheet()
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("dismissBookmarkSheet closes the sheet")
    func dismissCloses() {
        let viewModel = makeViewModel()
        viewModel.presentBookmarkSheet()
        viewModel.dismissBookmarkSheet()
        #expect(viewModel.presentedBookmarkSheet == nil)
    }

    // MARK: - Toggle

    @Test("toggleBookmark writes the presented chapter through the repository")
    func toggleWritesThroughRepository() async {
        let repository = SpyBookmarkRepository()
        let viewModel = makeViewModel(bookmarkRepository: repository)
        viewModel.presentBookmarkSheet()
        viewModel.toggleBookmark(color: .clay)
        await viewModel._waitForPendingBookmarkWrite()
        let toggles = await repository.toggles
        #expect(toggles == [.init(color: .clay, bookId: "ROM", chapterNumber: 8, at: now)])
    }

    @Test("toggleBookmark targets the sheet's captured chapter, not a position the reader stepped to")
    func toggleUsesCapturedChapter() async {
        let repository = SpyBookmarkRepository()
        let viewModel = makeViewModel(bookmarkRepository: repository)
        viewModel.presentBookmarkSheet()
        // The reader steps while the sheet is up (e.g. a deep link lands);
        // the sheet's tap must still write the chapter it is titled with.
        viewModel.stepChapter(.next)
        viewModel.toggleBookmark(color: .gold)
        await viewModel._waitForPendingBookmarkWrite()
        let toggles = await repository.toggles
        #expect(toggles.first?.bookId == "ROM")
        #expect(toggles.first?.chapterNumber == 8)
    }

    @Test("toggleBookmark without a presented sheet is a no-op")
    func toggleWithoutSheetNoOps() async {
        let repository = SpyBookmarkRepository()
        let viewModel = makeViewModel(bookmarkRepository: repository)
        viewModel.toggleBookmark(color: .clay)
        await viewModel._waitForPendingBookmarkWrite()
        let toggles = await repository.toggles
        #expect(toggles.isEmpty)
    }

    @Test("toggleBookmark without a repository is a no-op")
    func toggleWithoutRepositoryNoOps() async {
        let viewModel = makeViewModel()
        viewModel.presentBookmarkSheet()
        viewModel.toggleBookmark(color: .clay)
        await viewModel._waitForPendingBookmarkWrite()
        #expect(viewModel.toast == nil)
    }

    @Test("a failing toggle surfaces the failure toast")
    func failingToggleToasts() async {
        let viewModel = makeViewModel(bookmarkRepository: FailingBookmarkRepository())
        viewModel.presentBookmarkSheet()
        viewModel.toggleBookmark(color: .clay)
        await viewModel._waitForPendingBookmarkWrite()
        #expect(viewModel.toast == "Couldn't update the bookmark.")
    }
}
