import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `BibleScreenViewModel` — default and restored reading position,
/// chapter stepping (within a book, across book boundaries, and the no-op at
/// the canon's ends), translation switching, and verse selection with its
/// citation, Copy, and chat-stub toast.
@Suite("BibleScreenViewModel")
@MainActor
struct BibleScreenViewModelTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeViewModel(
        repository: (any BibleReadingPositionRepository)? = nil,
        clipboard: any ClipboardWriter = SystemClipboard(),
        at position: BiblePosition = BibleScreenViewModel.defaultPosition
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            positionRepository: repository,
            clock: FixedClock(now),
            clipboard: clipboard,
            initialPosition: position
        )
    }

    @Test("load with no persisted position opens the default chapter")
    func loadDefault() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)
        #expect(viewModel.bookName == "1 Peter")
        #expect(viewModel.chapter?.number == 2)
    }

    @Test("load restores a persisted position")
    func loadPersisted() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        try await repository.save(BibleReadingPositionRecord(
            bookId: "ROM", chapterNumber: 8, translationId: "WEB", updatedAt: now
        ))
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()
        #expect(viewModel.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(viewModel.bookName == "Romans")
        #expect(viewModel.chapter?.number == 8)
    }

    @Test("stepping forward advances the chapter and persists it")
    func stepForwardPersists() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()                         // 1 Peter 2
        viewModel.stepChapter(.next)                    // 1 Peter 3
        #expect(viewModel.position == BiblePosition(bookId: "1PE", chapterNumber: 3))
        #expect(viewModel.chapter?.number == 3)

        await viewModel._waitForPendingPersist()
        let saved = try await repository.load()
        #expect(saved?.bookId == "1PE")
        #expect(saved?.chapterNumber == 3)
        #expect(saved?.updatedAt == now)
    }

    @Test("rapid steps persist the final position once drained")
    func rapidStepsPersistFinalPosition() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()                          // 1 Peter 2
        viewModel.stepChapter(.next)                     // 1 Peter 3
        viewModel.stepChapter(.next)                     // 1 Peter 4
        await viewModel._waitForPendingPersist()
        let saved = try await repository.load()
        #expect(saved?.bookId == "1PE")
        #expect(saved?.chapterNumber == 4)
    }

    @Test("stepping forward past the last chapter crosses into the next book")
    func stepForwardCrossesBook() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        // 1 Peter has 5 chapters; step from 2 to its last, then once more.
        for _ in 0..<3 { viewModel.stepChapter(.next) }   // 1PE 2 → 5
        #expect(viewModel.position == BiblePosition(bookId: "1PE", chapterNumber: 5))
        viewModel.stepChapter(.next)
        #expect(viewModel.position == BiblePosition(bookId: "2PE", chapterNumber: 1))
        #expect(viewModel.bookName == "2 Peter")
    }

    @Test("Genesis 1 cannot step backward and a step there is a no-op")
    func genesisStartCannotStepBackward() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "GEN", chapterNumber: 1))
        await viewModel.load()
        #expect(viewModel.canStepBackward == false)
        #expect(viewModel.previousChapterLabel == nil)
        viewModel.stepChapter(.previous)
        #expect(viewModel.position == BiblePosition(bookId: "GEN", chapterNumber: 1))
    }

    @Test("Revelation 22 cannot step forward and a step there is a no-op")
    func revelationEndCannotStepForward() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "REV", chapterNumber: 22))
        await viewModel.load()
        #expect(viewModel.canStepForward == false)
        #expect(viewModel.nextChapterLabel == nil)
        viewModel.stepChapter(.next)
        #expect(viewModel.position == BiblePosition(bookId: "REV", chapterNumber: 22))
    }

    @Test("footer labels name the adjacent chapters")
    func footerLabels() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2
        #expect(viewModel.previousChapterLabel == "1 Peter 1")
        #expect(viewModel.nextChapterLabel == "1 Peter 3")
    }

    @Test("a failing text loader leaves the chapter unavailable")
    func failedLoadLeavesChapterNil() async {
        let viewModel = BibleScreenViewModel(textLoader: ThrowingBibleTextLoader())
        await viewModel.load()
        #expect(viewModel.chapter == nil)
    }

    @Test("presenting the book sheet opens it with every book collapsed")
    func presentingBookSheetStartsCollapsed() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2
        #expect(viewModel.bookSheet == nil)

        viewModel.presentBookSheet()
        #expect(viewModel.bookSheet != nil)
        #expect(viewModel.bookSheet?.expandedBookId == nil)
    }

    @Test("dismissing the book sheet clears it")
    func dismissingBookSheetClearsIt() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentBookSheet()
        viewModel.dismissBookSheet()
        #expect(viewModel.bookSheet == nil)
    }

    @Test("selecting a chapter navigates there and closes the sheet")
    func selectingChapterNavigatesAndClosesSheet() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentBookSheet()

        viewModel.selectChapter(bookId: "ROM", chapterNumber: 8)
        #expect(viewModel.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(viewModel.bookName == "Romans")
        #expect(viewModel.chapter?.number == 8)
        #expect(viewModel.bookSheet == nil)
    }

    @Test("selecting an unknown book or out-of-range chapter is a no-op")
    func selectingInvalidChapterIsNoOp() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2

        viewModel.selectChapter(bookId: "1PE", chapterNumber: 99)
        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)

        viewModel.selectChapter(bookId: "ZZZ", chapterNumber: 1)
        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)
    }

    @Test("selecting a chapter persists the new position")
    func selectingChapterPersists() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()                          // 1 Peter 2
        viewModel.selectChapter(bookId: "ROM", chapterNumber: 8)

        await viewModel._waitForPendingPersist()
        let saved = try await repository.load()
        #expect(saved?.bookId == "ROM")
        #expect(saved?.chapterNumber == 8)
    }

    @Test("a fresh load opens in the default translation")
    func loadDefaultsToWEB() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.translation == .web)
    }

    @Test("load restores a persisted translation")
    func loadRestoresTranslation() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        try await repository.save(BibleReadingPositionRecord(
            bookId: "1PE", chapterNumber: 2, translationId: "ASV", updatedAt: now
        ))
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()
        #expect(viewModel.translation == .asv)
    }

    @Test("presenting and dismissing the translation sheet toggles the flag")
    func translationSheetPresentation() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.isTranslationSheetPresented == false)

        viewModel.presentTranslationSheet()
        #expect(viewModel.isTranslationSheetPresented)

        viewModel.dismissTranslationSheet()
        #expect(viewModel.isTranslationSheetPresented == false)
    }

    @Test("selecting a translation reloads the chapter and closes the sheet")
    func selectingTranslationReloadsChapter() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2, WEB
        let webChapter = viewModel.chapter
        viewModel.presentTranslationSheet()

        viewModel.selectTranslation(.kjv)
        #expect(viewModel.translation == .kjv)
        #expect(viewModel.isTranslationSheetPresented == false)
        #expect(viewModel.chapter?.number == 2)
        #expect(viewModel.chapter != webChapter, "the chapter should re-render in KJV text")
    }

    @Test("selecting the current translation just closes the sheet")
    func selectingCurrentTranslationIsNoOp() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // WEB
        let webChapter = viewModel.chapter
        viewModel.presentTranslationSheet()

        viewModel.selectTranslation(.web)
        #expect(viewModel.translation == .web)
        #expect(viewModel.isTranslationSheetPresented == false)
        #expect(viewModel.chapter == webChapter)
    }

    @Test("selecting a translation persists it")
    func selectingTranslationPersists() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()                          // 1 Peter 2, WEB
        viewModel.selectTranslation(.kjv)

        await viewModel._waitForPendingPersist()
        let saved = try await repository.load()
        #expect(saved?.translationId == "KJV")
        #expect(saved?.bookId == "1PE")
        #expect(saved?.chapterNumber == 2)
    }

    // MARK: Verse selection

    @Test("a fresh load has no verses selected")
    func freshLoadHasNoSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.selectedVerses.isEmpty)
        #expect(viewModel.selectionCitation == nil)
    }

    @Test("toggling a verse selects it, and toggling again clears it")
    func togglingAVerse() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2

        viewModel.toggleVerse(9)
        #expect(viewModel.selectedVerses == [9])
        #expect(viewModel.selectionCitation == "1 Peter 2:9")

        viewModel.toggleVerse(9)
        #expect(viewModel.selectedVerses.isEmpty)
        #expect(viewModel.selectionCitation == nil)
    }

    @Test("the selection citation compresses contiguous verses to a range")
    func multiVerseSelectionCitation() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2
        for verse in [9, 4, 6, 5] { viewModel.toggleVerse(verse) }
        #expect(viewModel.selectionCitation == "1 Peter 2:4-6, 9")
    }

    @Test("clearing the selection drops every verse")
    func clearSelectionDropsEverything() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(4)
        viewModel.toggleVerse(5)
        viewModel.clearSelection()
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("stepping to another chapter clears the selection")
    func steppingClearsSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.stepChapter(.next)
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("jumping to a chapter from the picker clears the selection")
    func selectingChapterClearsSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.selectChapter(bookId: "ROM", chapterNumber: 8)
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("switching translation clears the selection")
    func switchingTranslationClearsSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.selectTranslation(.kjv)
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("copying writes the verse text and citation, then clears the selection")
    func copyWritesPassageThenClears() async throws {
        let clipboard = FakeClipboard()
        let viewModel = makeViewModel(clipboard: clipboard)
        await viewModel.load()                          // 1 Peter 2, WEB
        viewModel.toggleVerse(9)
        viewModel.copySelection()

        let copied = try #require(clipboard.lastWritten)
        let suffix = "— 1 Peter 2:9 (WEB)"
        #expect(copied.hasSuffix(suffix))
        #expect(copied.count > suffix.count + 10, "the verse body should precede the citation")
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("the share text carries the selected verses and a range citation")
    func shareTextForMultiVerseSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(4)
        viewModel.toggleVerse(5)
        #expect(viewModel.selectionShareText?.hasSuffix("— 1 Peter 2:4-5 (WEB)") == true)
    }

    @Test("a verse straddling a paragraph boundary joins all its fragments")
    func straddlingVerseJoinsFragments() async {
        // In 1 Peter 2 (WEB) verse 6 spans a prose sentence and the poetry
        // quotation that follows it — the share text must carry both.
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(6)
        let share = viewModel.selectionShareText
        #expect(share?.contains("Because it is contained in Scripture") == true)
        #expect(share?.contains("Behold, I lay in Zion") == true)
    }

    @Test("there is no share text without a selection")
    func noShareTextWithoutSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.selectionShareText == nil)
    }

    @Test("the chat stub raises a coming-soon toast and clears the selection")
    func chatComingSoonToast() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.presentChatComingSoon()
        #expect(viewModel.toast != nil)
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("dismissing the toast clears it")
    func dismissToastClearsIt() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentChatComingSoon()
        viewModel.dismissToast()
        #expect(viewModel.toast == nil)
    }
}
