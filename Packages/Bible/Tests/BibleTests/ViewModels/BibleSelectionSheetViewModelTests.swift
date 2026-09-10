import Core
import Foundation
import Testing
@testable import Bible

/// Draft reading choices remain isolated until a single, bounded navigation commit.
@Suite("Bible selection sheet")
@MainActor
struct BibleSelectionSheetViewModelTests {
    @Test("staging either tab does not change the reader or persist intermediate choices")
    func draftsStayIsolated() async throws {
        let (model, repository) = await loadedModel()
        model.toggleVerse(5)
        let chapter = model.chapter
        let writes = await repository.saveAttempts.count
        model.presentSelectionSheet()
        let sheet = try #require(model.selectionSheet)
        sheet.bookPicker.query = "2 Corinthians"
        sheet.selectChapter(bookId: "2CO", chapterNumber: 13)
        sheet.tab = .translation
        sheet.translation = .web
        sheet.tab = .book

        #expect(sheet.bookPicker.query == "2 Corinthians")
        #expect(sheet.position == BiblePosition(bookId: "2CO", chapterNumber: 13))
        #expect(sheet.translation == .web)
        #expect(model.position == BibleScreenViewModel.defaultPosition)
        #expect(model.translation == .kjv)
        #expect(model.chapter == chapter)
        #expect(model.selectedVerses == [5])
        #expect(!model.canGoBack)
        await model._waitForPendingPersist()
        #expect(await repository.saveAttempts.count == writes)
    }

    @Test("Read persists one final chapter and translation and adds exactly one visit")
    func appliesTogether() async throws {
        let (model, repository) = await loadedModel()
        let writes = await repository.saveAttempts.count
        model.presentSelectionSheet()
        let sheet = try #require(model.selectionSheet)
        sheet.selectChapter(bookId: "2CO", chapterNumber: 13)
        sheet.translation = .web
        model.applySelection()
        await model._waitForPendingPersist()

        #expect(model.position == BiblePosition(bookId: "2CO", chapterNumber: 13))
        #expect(model.translation == .web)
        #expect(model.chapter?.number == 13)
        #expect(model.selectionSheet == nil)
        let saves = await repository.saveAttempts
        #expect(saves.count == writes + 1)
        let saved = try #require(saves.last)
        #expect(saved.bookId == "2CO")
        #expect(saved.chapterNumber == 13)
        #expect(saved.translationId == "WEB")
        let history = BibleNavigationHistoryPayload.restore(
            from: saved.navigationHistoryJSON,
            position: model.position,
            catalog: .standard
        )
        #expect(history.entries == [BibleScreenViewModel.defaultPosition, BiblePosition(bookId: "2CO", chapterNumber: 13)])
    }

    @Test("closing discards choices and reopening starts from the actual reader")
    func cancelAndReopen() async throws {
        let (model, repository) = await loadedModel()
        let writes = await repository.saveAttempts.count
        model.presentSelectionSheet()
        let first = try #require(model.selectionSheet)
        first.selectChapter(bookId: "2TH", chapterNumber: 3)
        first.translation = .asv
        first.bookPicker.query = "thess"
        first.tab = .translation
        model.dismissSelectionSheet()
        model.presentSelectionSheet()
        let next = try #require(model.selectionSheet)

        #expect(next !== first)
        #expect(next.position == BibleScreenViewModel.defaultPosition)
        #expect(next.translation == .kjv)
        #expect(next.tab == .book)
        #expect(next.bookPicker.query.isEmpty)
        #expect(next.bookPicker.expandedBookId == "1PE")
        await model._waitForPendingPersist()
        #expect(await repository.saveAttempts.count == writes)
    }

    @Test("translation preserves staged verse bounds and a plain chapter clears them")
    func rangeLifecycle() {
        let sheet = BibleSelectionSheetViewModel(position: BibleScreenViewModel.defaultPosition, translation: .kjv)
        sheet.selectVerseRange(bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 18)
        sheet.translation = .web
        sheet.tab = .translation
        sheet.tab = .book
        #expect(sheet.verseRange == 16...18)
        #expect(sheet.citation == "John 3:16-18")
        sheet.selectChapter(bookId: "JHN", chapterNumber: 3)
        #expect(sheet.verseRange == nil)
        #expect(sheet.citation == "John 3")
        #expect(sheet.translation == .web)
    }

    @Test("invalid draft positions and reversed verse bounds cannot replace the current choice")
    func invalidDrafts() {
        let sheet = BibleSelectionSheetViewModel(position: BibleScreenViewModel.defaultPosition, translation: .kjv)
        sheet.selectChapter(bookId: "ZZZ", chapterNumber: 1)
        sheet.selectChapter(bookId: "2TH", chapterNumber: 4)
        sheet.selectVerseRange(bookId: "JHN", chapterNumber: 0, verseStart: 1, verseEnd: 2)
        sheet.selectVerseRange(bookId: "JHN", chapterNumber: 3, verseStart: 0, verseEnd: 2)
        sheet.selectVerseRange(bookId: "JHN", chapterNumber: 3, verseStart: 18, verseEnd: 16)
        #expect(sheet.position == BibleScreenViewModel.defaultPosition)
        #expect(sheet.verseRange == nil)
    }

    @Test("Read bounds huge verse ranges to the real chapter without allocating the range")
    func boundedVerseCommit() async throws {
        let (model, _) = await loadedModel()
        model.presentSelectionSheet()
        let sheet = try #require(model.selectionSheet)
        sheet.selectVerseRange(bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: Int.max)
        sheet.translation = .web
        model.applySelection()
        await model._waitForPendingPersist()
        #expect(model.selectedVerses == Set(16...36))
        #expect(model.pendingScrollVerse == 16)
        #expect(model.translation == .web)
        #expect(!model.isActionSheetPresented)
        #expect(model.selectionSheet == nil)
    }

    @Test("translation-only Read keeps the forward history branch")
    func translationKeepsForwardHistory() async throws {
        let (model, _) = await loadedModel()
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        model.goBack()
        model.presentSelectionSheet()
        let sheet = try #require(model.selectionSheet)
        sheet.translation = .asv
        model.applySelection()
        await model._waitForPendingPersist()
        #expect(model.position == BibleScreenViewModel.defaultPosition)
        #expect(model.forwardDestination == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(model.translation == .asv)
        #expect(!model.canGoBack)
    }

    @Test("the selector cannot open while reading history is restoring")
    func restoreGuardsPresentation() {
        let model = makeModel(GatedBibleReadingPositionRepository())
        model.presentSelectionSheet()
        model.applySelection()
        #expect(model.selectionSheet == nil)
        #expect(model.isRestoringNavigation)
    }

    private func loadedModel() async -> (BibleScreenViewModel, GatedBibleReadingPositionRepository) {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeModel(repository)
        let loading = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.success(nil))
        await loading.value
        await model._waitForPendingPersist()
        return (model, repository)
    }

    private func makeModel(_ repository: GatedBibleReadingPositionRepository) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(), positionRepository: repository,
            clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)),
            narration: NarrationController(service: FakeNarrationService())
        )
    }
}
