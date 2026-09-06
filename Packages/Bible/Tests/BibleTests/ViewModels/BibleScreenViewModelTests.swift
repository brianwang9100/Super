import Core
import Foundation
import GRDB
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
        highlightRepository: (any BibleHighlightRepository)? = nil,
        clipboard: any ClipboardWriter = FakeClipboard(),
        at position: BiblePosition = BibleScreenViewModel.defaultPosition,
        narration: NarrationController? = nil,
        hapticsEngine: any HapticsEngine = NoOpHapticsEngine()
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            positionRepository: repository,
            highlightRepository: highlightRepository,
            clock: FixedClock(now),
            clipboard: clipboard,
            initialPosition: position,
            narration: narration ?? NarrationController(service: FakeNarrationService()),
            hapticsEngine: hapticsEngine
        )
    }

    /// A view model wired to a fresh in-memory highlight store, returned
    /// alongside the database so a test can assert the persisted rows.
    private func makeHighlightingViewModel() throws -> (BibleScreenViewModel, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleHighlightRepository(
            database: database, ids: DeterministicIDGenerator()
        )
        return (makeViewModel(highlightRepository: repository), database)
    }

    /// The active highlights persisted for 1 Peter 2.
    private func highlights(in database: BibleDatabase) throws -> [BibleHighlightRecord] {
        try database.queue.read { db in
            try ChapterHighlightsRequest(bookId: "1PE", chapterNumber: 2).fetch(db)
        }
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

    @Test("presenting the book sheet opens it with the current book expanded")
    func presentingBookSheetExpandsCurrentBook() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2
        #expect(viewModel.bookSheet == nil)

        viewModel.presentBookSheet()
        #expect(viewModel.bookSheet != nil)
        #expect(viewModel.bookSheet?.expandedBookId == "1PE")
        #expect(viewModel.bookSheet?.currentPosition == viewModel.position)
    }

    @Test("dismissing the book sheet clears it")
    func dismissingBookSheetClearsIt() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentBookSheet()
        viewModel.dismissBookSheet()
        #expect(viewModel.bookSheet == nil)
    }

    @Test("reopening the book sheet hands a fresh view model anchored on the current chapter")
    func reopeningBookSheetReanchorsOnCurrentPosition() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2

        viewModel.presentBookSheet()
        let firstSheet = viewModel.bookSheet
        // Simulate the reader touching the picker — searching, switching
        // order — before dismissing without picking a chapter.
        firstSheet?.query = "psalms"
        firstSheet?.order = .alphabetical
        viewModel.dismissBookSheet()

        viewModel.presentBookSheet()
        let secondSheet = viewModel.bookSheet

        // The reopened sheet is a fresh instance with a clean query and
        // ordering, and its anchor still resolves to the current position.
        #expect(secondSheet !== firstSheet)
        #expect(secondSheet?.query.isEmpty == true)
        #expect(secondSheet?.order == .traditional)
        #expect(secondSheet?.expandedBookId == "1PE")
        #expect(secondSheet?.initialScrollAnchor == .bookRow(bookId: "1PE"))
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
    func loadDefaultsToKJV() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.translation == .kjv)
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
        await viewModel.load()                          // 1 Peter 2, KJV
        let kjvChapter = viewModel.chapter
        viewModel.presentTranslationSheet()

        viewModel.selectTranslation(.web)
        #expect(viewModel.translation == .web)
        #expect(viewModel.isTranslationSheetPresented == false)
        #expect(viewModel.chapter?.number == 2)
        #expect(viewModel.chapter != kjvChapter, "the chapter should re-render in WEB text")
    }

    @Test("selecting the current translation just closes the sheet")
    func selectingCurrentTranslationIsNoOp() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // KJV
        let kjvChapter = viewModel.chapter
        viewModel.presentTranslationSheet()

        viewModel.selectTranslation(.kjv)
        #expect(viewModel.translation == .kjv)
        #expect(viewModel.isTranslationSheetPresented == false)
        #expect(viewModel.chapter == kjvChapter)
    }

    @Test("selecting a translation persists it")
    func selectingTranslationPersists() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()                          // 1 Peter 2, KJV
        viewModel.selectTranslation(.web)

        await viewModel._waitForPendingPersist()
        let saved = try await repository.load()
        #expect(saved?.translationId == "WEB")
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
        #expect(!viewModel.isActionSheetPresented)
    }

    @Test("toggling a verse selects it, and toggling again clears it")
    func togglingAVerse() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2

        viewModel.toggleVerse(9)
        #expect(viewModel.selectedVerses == [9])
        #expect(viewModel.selectionCitation == "1 Peter 2:9")
        #expect(viewModel.isActionSheetPresented)

        viewModel.toggleVerse(9)
        #expect(viewModel.selectedVerses.isEmpty)
        #expect(viewModel.selectionCitation == nil)
        #expect(!viewModel.isActionSheetPresented)
    }

    @Test("dismissing verse actions preserves single and multiple selections without deselection haptics",
          arguments: [[9], [4, 5, 9]])
    func dismissingActionSheetPreservesSelection(verses: [Int]) async {
        let haptics = RecordingHapticsEngine()
        let viewModel = makeViewModel(hapticsEngine: haptics)
        await viewModel.load()
        for verse in verses { viewModel.toggleVerse(verse) }
        let citation = viewModel.selectionCitation
        let shareText = viewModel.selectionShareText

        viewModel.dismissActionSheet()
        viewModel.dismissActionSheet()

        #expect(!viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses == Set(verses))
        #expect(viewModel.selectionCitation == citation)
        #expect(viewModel.selectionShareText == shareText)
        #expect(haptics.played == verses.map { _ in HapticPattern.selection })
    }

    @Test("the nav bar clear action removes a retained selection", arguments: [false, true])
    func clearSelectionClosesActionSheet(afterDismissal: Bool) async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(4)
        viewModel.toggleVerse(9)
        if afterDismissal { viewModel.dismissActionSheet() }

        viewModel.clearSelection()

        #expect(viewModel.selectedVerses.isEmpty)
        #expect(viewModel.selectionCitation == nil)
        #expect(!viewModel.isActionSheetPresented)
    }

    @Test("adding and removing verses keeps dismissed actions out of the way")
    func changingSelectionKeepsActionSheetDismissed() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(4)
        viewModel.dismissActionSheet()

        viewModel.toggleVerse(9)

        #expect(!viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses == [4, 9])

        viewModel.toggleVerse(4)
        #expect(!viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses == [9])

        viewModel.toggleVerse(5)
        #expect(!viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses == [5, 9])
    }

    @Test("the selection pill reopens actions for all retained verses")
    func presentingActionSheetKeepsSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(4)
        viewModel.dismissActionSheet()
        viewModel.toggleVerse(9)

        viewModel.presentActionSheet()
        viewModel.presentActionSheet()

        #expect(viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses == [4, 9])
        #expect(viewModel.selectionCitation == "1 Peter 2:4, 9")
    }

    @Test("actions cannot open without a selection")
    func presentingActionSheetWithoutSelectionIsNoOp() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentNarrationSheet()

        viewModel.presentActionSheet()

        #expect(!viewModel.isActionSheetPresented)
        #expect(viewModel.isNarrationSheetPresented)
    }

    @Test("starting a new selection presents actions again", arguments: [false, true])
    func startingNewSelectionPresentsActionSheet(clearAll: Bool) async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(4)
        viewModel.dismissActionSheet()
        if clearAll {
            viewModel.clearSelection()
        } else {
            viewModel.toggleVerse(4)
        }
        #expect(viewModel.selectedVerses.isEmpty)
        #expect(!viewModel.isActionSheetPresented)

        viewModel.toggleVerse(9)

        #expect(viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses == [9])
    }

    @Test("the selection pill replaces narration controls without stopping playback")
    func presentingActionSheetKeepsNarrationPlaying() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let viewModel = makeViewModel(narration: controller)
        await viewModel.load()
        viewModel.toggleVerse(4)
        viewModel.dismissActionSheet()
        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 4, text: "Verse four")])
        controller._simulateEvent(.started(verseNumber: 4))
        viewModel.presentNarrationSheet()

        viewModel.presentActionSheet()

        #expect(viewModel.isActionSheetPresented)
        #expect(!viewModel.isNarrationSheetPresented)
        #expect(viewModel.selectedVerses == [4])
        #expect(controller.state == .speaking)
        #expect(service.stopCallCount == 0)
    }

    @Test("deep links reopen dismissed actions and out-of-range references close them")
    func openingReferenceUpdatesActionSheet() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.dismissActionSheet()

        viewModel.openReference(bookId: "1PE", chapterNumber: 2, verseStart: 9, verseEnd: nil)
        #expect(viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses == [9])

        viewModel.openReference(bookId: "1PE", chapterNumber: 2, verseStart: 99, verseEnd: nil)
        #expect(!viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("selecting a verse fires .selection and deselecting fires the distinct .deselection")
    func toggleVerseFiresDistinctHaptics() async {
        let haptics = RecordingHapticsEngine()
        let viewModel = makeViewModel(hapticsEngine: haptics)
        await viewModel.load()                          // 1 Peter 2

        viewModel.toggleVerse(9)                        // select
        viewModel.toggleVerse(9)                        // deselect

        #expect(haptics.played == [.selection, .deselection])
    }

    @Test("clearing an active selection fires .deselection, but clearing nothing is silent")
    func clearSelectionFiresDeselectionWhenNonEmpty() async {
        let haptics = RecordingHapticsEngine()
        let viewModel = makeViewModel(hapticsEngine: haptics)
        await viewModel.load()

        // Clearing with nothing selected is a no-op — no disconnect buzz.
        viewModel.clearSelection()
        #expect(haptics.played.isEmpty)

        viewModel.toggleVerse(4)                        // .selection
        viewModel.clearSelection()                      // .deselection (nav bar ×)
        // A second clear is a no-op.
        viewModel.clearSelection()

        #expect(haptics.played == [.selection, .deselection])
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
        viewModel.selectTranslation(.web)
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("copying writes the verse text and citation, then clears the selection")
    func copyWritesPassageThenClears() async throws {
        let clipboard = FakeClipboard()
        let viewModel = makeViewModel(clipboard: clipboard)
        await viewModel.load()                          // 1 Peter 2, KJV
        viewModel.toggleVerse(9)
        viewModel.copySelection()

        let copied = try #require(clipboard.lastWritten)
        let suffix = "— 1 Peter 2:9 (KJV)"
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
        #expect(viewModel.selectionShareText?.hasSuffix("— 1 Peter 2:4-5 (KJV)") == true)
    }

    @Test("a verse straddling a paragraph boundary joins all its fragments")
    func straddlingVerseJoinsFragments() async {
        // In 1 Peter 2 (WEB) verse 6 spans a prose sentence and the poetry
        // quotation that follows it — the share text must carry both. KJV is
        // all prose, so switch to WEB to exercise the straddling case.
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.selectTranslation(.web)
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

    // MARK: Highlights

    @Test("applying a highlight paints every selected verse and keeps the sheet open")
    func applyHighlightPaintsSelectedVerses() async throws {
        let (viewModel, database) = try makeHighlightingViewModel()
        await viewModel.load()                          // 1 Peter 2
        viewModel.toggleVerse(4)
        viewModel.toggleVerse(5)
        viewModel.applyHighlight(.green)
        #expect(
            viewModel.selectedVerses == [4, 5],
            "applying a highlight keeps the selection so the action sheet stays open"
        )

        await viewModel._waitForPendingHighlightWrite()
        let rows = try highlights(in: database)
        #expect(rows.map(\.verseNumber) == [4, 5])
        #expect(rows.allSatisfy { $0.color == .green })
    }

    @Test("clearing a highlight soft-deletes it for every selected verse")
    func clearHighlightRemovesSelectedVerses() async throws {
        let (viewModel, database) = try makeHighlightingViewModel()
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.applyHighlight(.yellow)
        await viewModel._waitForPendingHighlightWrite()

        // The highlight path now keeps the selection, so verse 9 is still
        // selected here — clear its highlight directly without re-toggling.
        viewModel.clearHighlight()
        #expect(
            viewModel.selectedVerses == [9],
            "clearing a highlight keeps the selection so the action sheet stays open"
        )

        await viewModel._waitForPendingHighlightWrite()
        #expect(try highlights(in: database).isEmpty)
    }

    @Test("re-tapping the verse's current colour clears the highlight")
    func reapplyingActiveColorClearsHighlight() async throws {
        let (viewModel, database) = try makeHighlightingViewModel()
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.applyHighlight(.yellow)
        await viewModel._waitForPendingHighlightWrite()
        #expect(try highlights(in: database).map(\.verseNumber) == [9])

        // Verse 9 is still selected (the sheet stayed open); tap yellow again —
        // the toggle reads the live colour and clears instead of re-painting.
        viewModel.applyHighlight(.yellow)
        await viewModel._waitForPendingHighlightWrite()
        #expect(try highlights(in: database).isEmpty)
    }

    @Test("re-tapping a different colour recolours rather than clearing")
    func reapplyingDifferentColorRecolours() async throws {
        let (viewModel, database) = try makeHighlightingViewModel()
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.applyHighlight(.yellow)
        await viewModel._waitForPendingHighlightWrite()

        // Verse 9 is still selected (the sheet stayed open); tapping a different
        // colour recolours it rather than clearing.
        viewModel.applyHighlight(.green)
        await viewModel._waitForPendingHighlightWrite()

        let rows = try highlights(in: database)
        #expect(rows.map(\.verseNumber) == [9])
        #expect(rows.first?.color == .green)
    }

    @Test("re-tapping a colour over a mixed selection applies to all, never clears")
    func reapplyingColorToMixedSelectionApplies() async throws {
        let (viewModel, database) = try makeHighlightingViewModel()
        await viewModel.load()
        // Verse 4 is yellow; verse 5 is unhighlighted.
        viewModel.toggleVerse(4)
        viewModel.applyHighlight(.yellow)
        await viewModel._waitForPendingHighlightWrite()

        // Verse 4 is still selected (the sheet stayed open); add verse 5 so the
        // selection is mixed, then tap yellow — only verse 4 matches, so the tap
        // paints both rather than clearing.
        viewModel.toggleVerse(5)
        viewModel.applyHighlight(.yellow)
        await viewModel._waitForPendingHighlightWrite()

        let rows = try highlights(in: database)
        #expect(rows.map(\.verseNumber) == [4, 5])
        #expect(rows.allSatisfy { $0.color == .yellow })
    }

    @Test("applying a highlight with no selection writes nothing")
    func applyHighlightWithoutSelectionIsNoOp() async throws {
        let (viewModel, database) = try makeHighlightingViewModel()
        await viewModel.load()
        viewModel.applyHighlight(.blue)
        await viewModel._waitForPendingHighlightWrite()
        let count = try await database.queue.read { db in try BibleHighlightRecord.fetchCount(db) }
        #expect(count == 0)
    }

    @Test("applying a highlight without a highlight store leaves the selection intact")
    func applyHighlightWithoutRepositoryIsSafe() async {
        let viewModel = makeViewModel()                 // no highlight repository
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.applyHighlight(.pink)
        // The guard returns early without a store; the selection is untouched
        // either way (the highlight path now always keeps the sheet open).
        #expect(viewModel.selectedVerses == [9])
    }

    @Test("a failed highlight write surfaces a toast")
    func failedHighlightWriteShowsToast() async {
        let viewModel = makeViewModel(highlightRepository: ThrowingBibleHighlightRepository())
        await viewModel.load()
        viewModel.toggleVerse(9)
        viewModel.applyHighlight(.yellow)
        // The write is fire-and-forget; the toast must surface so a failed
        // write doesn't silently read as a successful highlight.
        await viewModel._waitForPendingHighlightWrite()
        #expect(viewModel.toast == "Couldn't save the highlight.")
    }

    // MARK: - Chat hand-off

    @Test("makeVerseReference returns nil when nothing is selected")
    func makeVerseReferenceNilWhenEmpty() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.makeVerseReference() == nil)
    }

    @Test("makeVerseReference carries the citation, applet id, and verse text")
    func makeVerseReferenceForSingleVerse() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2, KJV
        viewModel.toggleVerse(9)

        let reference = viewModel.makeVerseReference()
        #expect(reference?.appletID == "bible")
        #expect(reference?.kind == "verseRange")
        #expect(reference?.citation == "1 Peter 2:9 (KJV)")
        #expect(reference?.displayLabel == "1 Peter 2:9 (KJV)")
        #expect(reference?.snapshot.isEmpty == false)
    }

    @Test("makeVerseReference compresses a discontiguous selection in the citation")
    func makeVerseReferenceForDiscontiguousSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        for verse in [9, 4, 6, 5] { viewModel.toggleVerse(verse) }

        #expect(viewModel.makeVerseReference()?.citation == "1 Peter 2:4-6, 9 (KJV)")
    }

    @Test("makeVerseReference reflects the active translation")
    func makeVerseReferenceUsesActiveTranslation() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // KJV
        viewModel.selectTranslation(.web)
        viewModel.toggleVerse(9)

        let reference = viewModel.makeVerseReference()
        #expect(reference?.citation == "1 Peter 2:9 (WEB)")
        #expect(reference?.sourceID.hasPrefix("WEB/") == true)
    }

    // MARK: - Whole-chapter chat hand-off

    @Test("makeChapterReference returns the whole chapter's text + a colon-less citation")
    func makeChapterReferenceShape() async throws {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2, KJV

        let reference = try #require(viewModel.makeChapterReference())
        #expect(reference.appletID == "bible")
        #expect(reference.kind == "verseRange")
        // No verse component — the chapter citation drops the ":N" clause.
        #expect(reference.citation == "1 Peter 2 (KJV)")
        #expect(reference.displayLabel == "1 Peter 2 (KJV)")
        // Snapshot carries the whole chapter — at minimum the famous v9.
        #expect(reference.snapshot.contains("chosen race") || reference.snapshot.contains("chosen generation"))
        // sourceID encodes every verse in the chapter so a round-trip can
        // unambiguously rebuild the range. 1 Peter 2 has 25 verses (KJV).
        #expect(reference.sourceID.hasPrefix("KJV/1PE/2/"))
        let verses = reference.sourceID
            .split(separator: "/").last
            .map { String($0).split(separator: ",").compactMap { Int($0) } } ?? []
        #expect(verses == Array(1...25))
    }

    @Test("makeChapterReference reflects the active translation")
    func makeChapterReferenceUsesActiveTranslation() async throws {
        let viewModel = makeViewModel()
        await viewModel.load()                          // KJV
        viewModel.selectTranslation(.web)

        let reference = try #require(viewModel.makeChapterReference())
        #expect(reference.citation == "1 Peter 2 (WEB)")
        #expect(reference.sourceID.hasPrefix("WEB/1PE/2/"))
    }

    // MARK: - Narration

    @Test("startNarration with no selection queues every verse in reading order")
    func startNarrationWithoutSelectionQueuesAllVerses() async {
        let service = FakeNarrationService()
        let viewModel = makeViewModel(narration: NarrationController(service: service))
        await viewModel.load()                          // 1 Peter 2 has 25 verses

        viewModel.startNarration()
        // Starting is synchronous; only playback events arrive asynchronously.
        #expect(service.startCallCount == 1)
        let scheduled = service.lastStartArgs?.utterances.map(\.verseNumber) ?? []
        #expect(scheduled == Array(1...25))
        #expect(viewModel.isNarrationSheetPresented)
    }

    @Test("narration uses selected verses whether their action sheet is open or dismissed",
          arguments: [false, true])
    func startNarrationWithSelectionRestrictsToSortedVerses(dismissActions: Bool) async {
        let service = FakeNarrationService()
        let viewModel = makeViewModel(narration: NarrationController(service: service))
        await viewModel.load()
        for verse in [9, 3, 5] { viewModel.toggleVerse(verse) }
        if dismissActions { viewModel.dismissActionSheet() }

        viewModel.startNarration()
        let scheduled = service.lastStartArgs?.utterances.map(\.verseNumber) ?? []
        #expect(scheduled == [3, 5, 9])
        #expect(viewModel.isNarrationSheetPresented)
        #expect(viewModel.isActionSheetPresented == !dismissActions)

        viewModel.dismissNarrationSheet()
        #expect(!viewModel.isNarrationSheetPresented)
        #expect(viewModel.selectedVerses == [3, 5, 9])
        #expect(viewModel.isActionSheetPresented == !dismissActions)
    }

    @Test("startNarration is a no-op when the chapter text failed to load")
    func startNarrationWithoutChapterIsNoOp() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let viewModel = BibleScreenViewModel(
            textLoader: ThrowingBibleTextLoader(),
            narration: controller
        )
        await viewModel.load()                          // chapter == nil
        viewModel.startNarration()
        #expect(service.startCallCount == 0)
        #expect(viewModel.isNarrationSheetPresented == false)
    }

    @Test("narrationCitation reflects the controller's current verse")
    func narrationCitationReflectsControllerVerse() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let viewModel = makeViewModel(narration: controller)
        await viewModel.load()                          // 1 Peter 2

        #expect(viewModel.narrationCitation == nil)
        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 9, text: "x")])
        controller._simulateEvent(.started(verseNumber: 9))
        #expect(viewModel.narrationCitation == "1 Peter 2:9")
    }

    @Test("stepping a chapter stops the active narration")
    func steppingStopsNarration() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let viewModel = makeViewModel(narration: controller)
        await viewModel.load()

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "x")])
        controller._simulateEvent(.started(verseNumber: 1))

        viewModel.stepChapter(.next)
        // Strict `== 1`, not `>= 1`: `NarrationController.stop()`
        // guards on `state != .idle`, so the one navigation action
        // here forwards to `service.stop()` exactly once. A loose
        // bound would let a double-stop regression slip through.
        #expect(service.stopCallCount == 1)
    }

    @Test("selecting a translation stops the active narration")
    func selectingTranslationStopsNarration() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let viewModel = makeViewModel(narration: controller)
        await viewModel.load()                          // KJV

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "x")])
        controller._simulateEvent(.started(verseNumber: 1))

        viewModel.selectTranslation(.web)
        #expect(service.stopCallCount == 1)
    }

    @Test("jumping to a chapter from the picker stops the active narration")
    func selectingChapterStopsNarration() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let viewModel = makeViewModel(narration: controller)
        await viewModel.load()

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "x")])
        controller._simulateEvent(.started(verseNumber: 1))

        viewModel.selectChapter(bookId: "ROM", chapterNumber: 8)
        #expect(service.stopCallCount == 1)
    }

    @Test("presentNarrationSheet sets the presentation flag without starting narration")
    func presentingNarrationSheetSetsFlag() async {
        let service = FakeNarrationService()
        let viewModel = makeViewModel(narration: NarrationController(service: service))
        await viewModel.load()
        #expect(viewModel.isNarrationSheetPresented == false)

        viewModel.presentNarrationSheet()
        #expect(viewModel.isNarrationSheetPresented)
        #expect(service.startCallCount == 0)
    }

    @Test("dismissNarrationSheet flips the flag without stopping narration")
    func dismissNarrationSheetDoesNotStop() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let viewModel = makeViewModel(narration: controller)
        await viewModel.load()

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "x")])
        controller._simulateEvent(.started(verseNumber: 1))
        viewModel.presentNarrationSheet()

        viewModel.dismissNarrationSheet()
        #expect(viewModel.isNarrationSheetPresented == false)
        #expect(service.stopCallCount == 0, "dismissing the sheet must keep narration playing")
    }

    // MARK: - openReference

    @Test("openReference with a verse range navigates and pre-selects the range")
    func openReferenceWithRangeSelectsAllVerses() async {
        let viewModel = makeViewModel()
        await viewModel.load() // 1 Peter 2
        viewModel.openReference(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)

        #expect(viewModel.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(viewModel.bookName == "Romans")
        #expect(viewModel.chapter?.number == 8)
        #expect(viewModel.selectedVerses == [28, 29, 30])
    }

    @Test("openReference with a single verse pre-selects just that verse")
    func openReferenceWithSingleVerseSelectsOne() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.openReference(bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: nil)

        #expect(viewModel.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(viewModel.selectedVerses == [16])
    }

    @Test("openReference chapter-only leaves no verse selection")
    func openReferenceChapterOnlyLeavesEmptySelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.openReference(bookId: "PSA", chapterNumber: 23, verseStart: nil, verseEnd: nil)

        #expect(viewModel.position == BiblePosition(bookId: "PSA", chapterNumber: 23))
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("openReference with unknown book is a no-op")
    func openReferenceUnknownBookIsNoOp() async {
        let viewModel = makeViewModel()
        await viewModel.load() // 1 Peter 2
        viewModel.openReference(bookId: "ZZZ", chapterNumber: 1, verseStart: 1, verseEnd: nil)

        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)
        #expect(viewModel.selectedVerses.isEmpty)
    }

    @Test("openReference with out-of-range chapter is a no-op")
    func openReferenceOutOfRangeChapterIsNoOp() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        // Genesis has 50 chapters.
        viewModel.openReference(bookId: "GEN", chapterNumber: 51, verseStart: 1, verseEnd: nil)

        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)
    }

    @Test("openReference with an inverted verse range is a no-op")
    func openReferenceInvertedRangeIsNoOp() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.openReference(bookId: "ROM", chapterNumber: 8, verseStart: 10, verseEnd: 5)

        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)
    }

    @Test("openReference drops pre-selected verses past the chapter's last verse")
    func openReferenceDropsOutOfRangeVerses() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        // Revelation 22 has 21 verses; 22 is past the end.
        viewModel.openReference(bookId: "REV", chapterNumber: 22, verseStart: 22, verseEnd: 22)

        #expect(viewModel.position == BiblePosition(bookId: "REV", chapterNumber: 22))
        #expect(viewModel.selectedVerses.isEmpty)            // no ghost selection
        #expect(viewModel.selectionCitation == nil)          // action bar stays off
    }

    @Test("openReference clamps a partly-out-of-range range to the real verses")
    func openReferenceClampsPartlyOutOfRange() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        // Revelation 22:20-23 → only 20 and 21 exist.
        viewModel.openReference(bookId: "REV", chapterNumber: 22, verseStart: 20, verseEnd: 23)

        #expect(viewModel.selectedVerses == [20, 21])
    }

    @Test("openReference persists the new position")
    func openReferencePersistsNewPosition() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load() // 1 Peter 2
        viewModel.openReference(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)

        await viewModel._waitForPendingPersist()
        let saved = try await repository.load()
        #expect(saved?.bookId == "ROM")
        #expect(saved?.chapterNumber == 8)
    }

    @Test("openReference closes the book sheet if it was open")
    func openReferenceClosesBookSheet() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentBookSheet()
        #expect(viewModel.bookSheet != nil)

        viewModel.openReference(bookId: "JHN", chapterNumber: 1, verseStart: 1, verseEnd: nil)
        #expect(viewModel.bookSheet == nil)
    }

    @Test("openReference sets pendingScrollVerse to the first verse")
    func openReferenceSignalsScrollTarget() async {
        let viewModel = makeViewModel()
        await viewModel.load()

        viewModel.openReference(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        #expect(viewModel.pendingScrollVerse == 28)
    }

    @Test("openReference for a chapter-only navigation leaves pendingScrollVerse nil")
    func openReferenceChapterOnlyLeavesScrollTargetNil() async {
        let viewModel = makeViewModel()
        await viewModel.load()

        viewModel.openReference(bookId: "PSA", chapterNumber: 23, verseStart: nil, verseEnd: nil)
        #expect(viewModel.pendingScrollVerse == nil)
    }

    @Test("consumePendingScrollVerse returns and clears the target")
    func consumePendingScrollVerseClearsTarget() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.openReference(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: nil)

        #expect(viewModel.consumePendingScrollVerse() == 28)
        #expect(viewModel.pendingScrollVerse == nil)
        // A second consume is a no-op — returns nil and the slot stays clear.
        #expect(viewModel.consumePendingScrollVerse() == nil)
    }
}
