import Core
import Foundation
import GRDB
import Testing
@testable import Bible

@Suite("BibleScreenViewModel navigation history")
@MainActor
struct BibleScreenViewModelHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeViewModel(
        repository: (any BibleReadingPositionRepository)? = nil,
        at position: BiblePosition = BibleScreenViewModel.defaultPosition,
        narration: NarrationController? = nil
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            positionRepository: repository,
            clock: FixedClock(now),
            initialPosition: position,
            narration: narration ?? NarrationController(service: FakeNarrationService())
        )
    }

    private func record(
        position: BiblePosition,
        translation: BibleTranslation = .kjv,
        history: BibleNavigationHistory? = nil
    ) throws -> BibleReadingPositionRecord {
        BibleReadingPositionRecord(
            bookId: position.bookId,
            chapterNumber: position.chapterNumber,
            translationId: translation.rawValue,
            updatedAt: now,
            navigationHistoryJSON: try history.map(BibleNavigationHistoryPayload.encode)
        )
    }

    private func restoredHistory(from record: BibleReadingPositionRecord) -> BibleNavigationHistory {
        BibleNavigationHistoryPayload.restore(
            from: record.navigationHistoryJSON,
            position: BiblePosition(bookId: record.bookId, chapterNumber: record.chapterNumber),
            catalog: .standard
        )
    }

    @Test("visits, traversal, translation, and branching follow browser history semantics")
    func sourceRouteRegression() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let model = makeViewModel(repository: repository)

        await model.load()
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        model.openReference(bookId: "PSA", chapterNumber: 23, verseStart: 1, verseEnd: 2)
        model.goBack()
        #expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(model.canGoForward)
        model.selectTranslation(.web)
        #expect(model.canGoForward)
        model.stepChapter(.next)
        #expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 4))
        #expect(!model.canGoForward)
        await model._waitForPendingPersist()

        let saved = try #require(try await repository.load())
        let history = restoredHistory(from: saved)
        #expect(history.entries == [
            BibleScreenViewModel.defaultPosition,
            BiblePosition(bookId: "JHN", chapterNumber: 3),
            BiblePosition(bookId: "JHN", chapterNumber: 4),
        ])
        #expect(saved.translationId == "WEB")
    }

    @Test("a fresh model restores the final cursor and forward entries")
    func restoresCursorAndForwardEntries() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let first = makeViewModel(repository: repository)
        await first.load()
        first.selectChapter(bookId: "JHN", chapterNumber: 3)
        first.selectChapter(bookId: "PSA", chapterNumber: 23)
        first.goBack()
        await first._waitForPendingPersist()

        let restored = makeViewModel(repository: repository)
        await restored.load()
        #expect(restored.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(restored.backDestination == BibleScreenViewModel.defaultPosition)
        #expect(restored.forwardDestination == BiblePosition(bookId: "PSA", chapterNumber: 23))
        restored.goForward()
        #expect(restored.position == BiblePosition(bookId: "PSA", chapterNumber: 23))
    }

    @Test("initial restore is single-flight and drains queued absolute intents in order")
    func initialRestoreQueuesIntentsAndSharesLoad() async throws {
        var history = BibleNavigationHistory(initialPosition: BiblePosition(bookId: "GEN", chapterNumber: 1))
        history.visit(BiblePosition(bookId: "ROM", chapterNumber: 8))
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)

        #expect(model.isRestoringNavigation)
        model.selectTranslation(.web)
        model.openReference(bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: nil)
        model.selectTranslation(.bsb)
        model.openReference(bookId: "PSA", chapterNumber: 23, verseStart: 1, verseEnd: 2)
        let firstLoad = Task { await model.load() }
        let secondLoad = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        model.stepChapter(.next)
        model.goBack()
        await repository.releaseNextLoad(.success(try record(
            position: BiblePosition(bookId: "ROM", chapterNumber: 8),
            translation: .asv,
            history: history
        )))
        await firstLoad.value
        await secondLoad.value
        await model.load()
        await model._waitForPendingPersist()

        #expect(await repository.loadCallCount == 1)
        #expect(!model.isRestoringNavigation)
        #expect(model.position == BiblePosition(bookId: "PSA", chapterNumber: 23))
        #expect(model.translation == .bsb)
        #expect(model.selectedVerses == [1, 2])
        #expect(model.backDestination == BiblePosition(bookId: "JHN", chapterNumber: 3))
    }

    @Test("read failure enables session navigation without overwriting disk")
    func readFailureSuppressesWrites() async {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await load.value

        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        model.selectChapter(bookId: "PSA", chapterNumber: 23)
        model.goBack()
        model.selectChapter(bookId: "ROM", chapterNumber: 8)
        await model._waitForPendingPersist()

        #expect(model.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(model.navigationPersistenceError != nil)
        #expect(await repository.saveAttempts.isEmpty)
    }

    @Test("retry recovers disk history and appends only the final provisional destination")
    func retryKeepsFinalProvisionalDestination() async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await load.value

        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        model.selectChapter(bookId: "PSA", chapterNumber: 23)
        model.goBack()
        model.selectChapter(bookId: "ROM", chapterNumber: 8)
        model.selectTranslation(.web)

        let retry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        #expect(model.isRestoringNavigation)
        await repository.releaseNextLoad(.success(try record(
            position: BibleScreenViewModel.defaultPosition,
            translation: .asv
        )))
        await retry.value

        #expect(model.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(model.translation == .web)
        #expect(!model.canGoForward)
        let saved = try #require(await repository.currentRecord())
        #expect(restoredHistory(from: saved).entries == [
            BibleScreenViewModel.defaultPosition,
            BiblePosition(bookId: "ROM", chapterNumber: 8),
        ])
        #expect(saved.translationId == "WEB")
        #expect(model.navigationPersistenceError == nil)
    }

    @Test("retry immediately after Back preserves the visible destination and omits forward provisional visits")
    func retryAfterBackKeepsVisibleDestination() async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await load.value

        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        model.selectChapter(bookId: "PSA", chapterNumber: 23)
        model.goBack()
        let retry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        await repository.releaseNextLoad(.success(try record(
            position: BibleScreenViewModel.defaultPosition
        )))
        await retry.value

        #expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(!model.canGoForward)
        let saved = try #require(await repository.currentRecord())
        #expect(restoredHistory(from: saved).entries == [
            BibleScreenViewModel.defaultPosition,
            BiblePosition(bookId: "JHN", chapterNumber: 3),
        ])
    }

    @Test("retry gates new intents and drains them after reconciliation")
    func retryQueuesIncomingIntents() async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await load.value

        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        let retryOne = Task { await model.retryNavigationPersistence() }
        let retryTwo = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        model.openReference(bookId: "PSA", chapterNumber: 23, verseStart: 1, verseEnd: 2)
        model.selectTranslation(.bsb)
        model.openReference(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        model.stepChapter(.next)
        await repository.releaseNextLoad(.success(try record(
            position: BibleScreenViewModel.defaultPosition,
            translation: .asv
        )))
        await retryOne.value
        await retryTwo.value

        #expect(await repository.loadCallCount == 2)
        #expect(model.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(model.translation == .bsb)
        #expect(model.selectedVerses == [28, 29, 30])
        #expect(model.backDestination == BiblePosition(bookId: "PSA", chapterNumber: 23))
    }

    @Test("concurrent failed retries share the same failed read")
    func concurrentFailedRetriesAreSingleFlight() async {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await load.value

        let firstRetry = Task { await model.retryNavigationPersistence() }
        let secondRetry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        await repository.releaseNextLoad(.failure)
        await firstRetry.value
        await secondRetry.value

        #expect(await repository.loadCallCount == 2)
        #expect(model.navigationPersistenceError != nil)
        #expect(!model.isRestoringNavigation)
    }

    @Test("successful retry clears state bound to the provisional chapter")
    func retryClearsProvisionalChapterState() async throws {
        let repository = GatedBibleReadingPositionRepository()
        let service = FakeNarrationService()
        let narration = NarrationController(service: service)
        let model = makeViewModel(repository: repository, narration: narration)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await load.value

        model.toggleVerse(9)
        model.presentBookmarkSheet()
        model.presentNoteList(for: .chapter(bookId: "1PE", chapterNumber: 2))
        model.presentAnnotationSheet(for: .chapter(bookId: "1PE", chapterNumber: 2))
        model.presentNarrationSheet()
        narration.start(utterances: [NarrationVerseUtterance(verseNumber: 9, text: "test")])
        narration._simulateEvent(.started(verseNumber: 9))

        let retry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        await repository.releaseNextLoad(.success(try record(
            position: BiblePosition(bookId: "ROM", chapterNumber: 8)
        )))
        await retry.value

        #expect(model.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(model.selectedVerses.isEmpty)
        #expect(model.presentedBookmarkSheet == nil)
        #expect(model.presentedNoteList == nil)
        #expect(model.presentedAnnotationTarget == nil)
        #expect(!model.isNarrationSheetPresented)
        #expect(service.stopCallCount == 1)
    }

    @Test("real traversal clears chapter state while same-chapter references preserve the forward branch")
    func traversalCleanupAndSameChapterNoOp() async {
        let service = FakeNarrationService()
        let narration = NarrationController(service: service)
        let model = makeViewModel(narration: narration)
        await model.load()
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        model.selectChapter(bookId: "PSA", chapterNumber: 23)
        model.goBack()
        model.openReference(bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: nil)
        #expect(model.canGoForward)
        #expect(model.selectedVerses == [16])
        #expect(model.pendingScrollVerse == 16)

        model.presentBookmarkSheet()
        model.presentNoteList(for: .chapter(bookId: "JHN", chapterNumber: 3))
        model.presentAnnotationSheet(for: .chapter(bookId: "JHN", chapterNumber: 3))
        model.presentNarrationSheet()
        narration.start(utterances: [NarrationVerseUtterance(verseNumber: 16, text: "test")])
        narration._simulateEvent(.started(verseNumber: 16))
        model.updateScroll(offsetY: 100, userDriven: true)
        model.updateScroll(offsetY: 130, userDriven: true)
        model.updateFooterVisibility(true)
        model.goForward()

        #expect(model.position == BiblePosition(bookId: "PSA", chapterNumber: 23))
        #expect(model.selectedVerses.isEmpty)
        #expect(model.pendingScrollVerse == nil)
        #expect(model.presentedBookmarkSheet == nil)
        #expect(model.presentedNoteList == nil)
        #expect(model.presentedAnnotationTarget == nil)
        #expect(!model.isNarrationSheetPresented)
        #expect(!model.isImmersive)
        #expect(!model.isChapterFooterVisible)
        #expect(service.stopCallCount > 0)
    }

    @Test("invalid absolute routes after Back preserve the forward branch")
    func invalidRoutesPreserveForwardBranch() async {
        let model = makeViewModel()
        await model.load()
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        model.selectChapter(bookId: "PSA", chapterNumber: 23)
        model.goBack()

        model.selectChapter(bookId: "ZZZ", chapterNumber: 1)
        model.selectChapter(bookId: "GEN", chapterNumber: 51)
        model.openReference(bookId: "ROM", chapterNumber: 8, verseStart: 10, verseEnd: 5)

        #expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(model.forwardDestination == BiblePosition(bookId: "PSA", chapterNumber: 23))
    }

    @Test("an invalid saved chapter falls back while preserving translation and repairing history")
    func invalidSavedChapterFallsBackAndRepairs() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        try await repository.save(BibleReadingPositionRecord(
            bookId: "ZZZ",
            chapterNumber: 99,
            translationId: "WEB",
            updatedAt: now,
            navigationHistoryJSON: "{malformed"
        ))
        let model = makeViewModel(repository: repository)
        await model.load()
        await model._waitForPendingPersist()

        #expect(model.position == BibleScreenViewModel.defaultPosition)
        #expect(model.translation == .web)
        let saved = try #require(try await repository.load())
        #expect(restoredHistory(from: saved).entries == [BibleScreenViewModel.defaultPosition])
        #expect(saved.translationId == "WEB")
    }

    @Test("a text-unavailable destination remains in traversable history")
    func unavailableTextRemainsTraversable() async {
        let model = BibleScreenViewModel(
            textLoader: ThrowingBibleTextLoader(),
            narration: NarrationController(service: FakeNarrationService())
        )
        await model.load()
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        #expect(model.chapter == nil)
        model.goBack()
        #expect(model.position == BibleScreenViewModel.defaultPosition)
        #expect(model.forwardDestination == BiblePosition(bookId: "JHN", chapterNumber: 3))
        model.goForward()
        #expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(model.chapter == nil)
    }

    @Test("explicit same-current choices override recovered disk state")
    func explicitSameCurrentChoicesSurviveRecovery() async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await load.value

        model.selectTranslation(.kjv)
        model.openReference(
            bookId: BibleScreenViewModel.defaultPosition.bookId,
            chapterNumber: BibleScreenViewModel.defaultPosition.chapterNumber,
            verseStart: nil,
            verseEnd: nil
        )
        let retry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        await repository.releaseNextLoad(.success(try record(
            position: BiblePosition(bookId: "ROM", chapterNumber: 8),
            translation: .web
        )))
        await retry.value

        #expect(model.position == BibleScreenViewModel.defaultPosition)
        #expect(model.translation == .kjv)
        #expect(model.backDestination == BiblePosition(bookId: "ROM", chapterNumber: 8))
    }

    @Test("huge reference ends select only verses present in the loaded chapter")
    func hugeVerseEndDoesNotAllocateRange() async {
        let model = makeViewModel()
        await model.load()
        model.openReference(
            bookId: "REV",
            chapterNumber: 22,
            verseStart: 20,
            verseEnd: Int.max
        )
        #expect(model.selectedVerses == [20, 21])
    }

    @Test("failed write is visible and retry writes the latest complete snapshot")
    func saveFailureRetriesLatestSnapshot() async {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.success(nil))
        await load.value
        await model._waitForPendingPersist()

        await repository.enqueueSaveResult(.failure)
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        await model._waitForPendingPersist()
        #expect(model.navigationPersistenceError != nil)

        model.selectChapter(bookId: "PSA", chapterNumber: 23)
        await model.retryNavigationPersistence()
        let saved = await repository.currentRecord()
        #expect(saved?.bookId == "PSA")
        #expect(saved?.chapterNumber == 23)
        #expect(saved.map(restoredHistory)?.entries.last == BiblePosition(bookId: "PSA", chapterNumber: 23))
        #expect(model.navigationPersistenceError == nil)
    }

    @Test("an older failed save cannot replace a newer successful save with stale error UI")
    func staleSaveFailureIsSuppressed() async {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.success(nil))
        await load.value
        await model._waitForPendingPersist()

        await repository.suspendNextSave()
        await repository.enqueueSaveResult(.failure)
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        await repository.waitForSaveAttempt(count: 2)
        model.selectChapter(bookId: "PSA", chapterNumber: 23)
        await repository.releaseSuspendedSave()
        await model._waitForPendingPersist()

        #expect(model.navigationPersistenceError == nil)
        #expect(await repository.currentRecord()?.bookId == "PSA")
    }

    @Test("rapid mixed navigation captures immutable complete snapshots in order")
    func rapidMixedNavigationPersistsOrderedSnapshots() async {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.success(nil))
        await load.value
        await model._waitForPendingPersist()

        await repository.suspendNextSave()
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        await repository.waitForSaveAttempt(count: 2)
        model.selectTranslation(.web)
        model.goBack()
        model.goForward()
        model.openReference(bookId: "PSA", chapterNumber: 23, verseStart: nil, verseEnd: nil)
        await repository.releaseSuspendedSave()
        await model._waitForPendingPersist()

        let attempts = await repository.saveAttempts
        #expect(attempts.map(\.bookId) == ["1PE", "JHN", "JHN", "1PE", "JHN", "PSA"])
        #expect(attempts.map(\.translationId) == ["KJV", "KJV", "WEB", "WEB", "WEB", "WEB"])
        #expect(attempts.map(restoredHistory).map(\.currentIndex) == [0, 1, 1, 0, 1, 2])
        #expect(restoredHistory(from: attempts[3]).entries == [
            BibleScreenViewModel.defaultPosition,
            BiblePosition(bookId: "JHN", chapterNumber: 3),
        ])
        #expect(restoredHistory(from: attempts[5]).entries == [
            BibleScreenViewModel.defaultPosition,
            BiblePosition(bookId: "JHN", chapterNumber: 3),
            BiblePosition(bookId: "PSA", chapterNumber: 23),
        ])
    }

    @Test("flush waits for restore and persists intents queued behind it")
    func flushWaitsForRestore() async {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeViewModel(repository: repository)
        let flush = Task { await model.flushNavigationPersistence() }
        await repository.waitForLoadCall(count: 1)
        model.openReference(bookId: "ROM", chapterNumber: 8, verseStart: nil, verseEnd: nil)
        model.selectTranslation(.web)
        await repository.releaseNextLoad(.success(nil))
        await flush.value

        let saved = await repository.currentRecord()
        #expect(saved?.bookId == "ROM")
        #expect(saved?.chapterNumber == 8)
        #expect(saved?.translationId == "WEB")
    }

    @Test("nil repository retains session-only history")
    func nilRepositoryHistory() async {
        let model = makeViewModel()
        await model.load()
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        model.selectChapter(bookId: "PSA", chapterNumber: 23)
        model.goBack()

        #expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(model.canGoBack)
        #expect(model.canGoForward)
        #expect(model.navigationPersistenceError == nil)
        await model.flushNavigationPersistence()
    }
}
