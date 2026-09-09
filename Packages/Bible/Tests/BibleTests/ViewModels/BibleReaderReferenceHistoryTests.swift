import Core
import Foundation
import Testing
@testable import Bible

@Suite("Bible reader reference history")
@MainActor
struct BibleReaderReferenceHistoryTests {
    private let genesis = BiblePosition(bookId: "GEN", chapterNumber: 1)
    private let romans = BiblePosition(bookId: "ROM", chapterNumber: 8)
    private let john = BiblePosition(bookId: "JHN", chapterNumber: 3)

    @Test("exact handoffs before initial restore append one visit with captured selection", arguments: [Set<Int>(), [16, 18]])
    func handoffBeforeInitialRestore(verses: Set<Int>) async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeModel(repository)
        let target = BibleReaderReference(position: john, translation: .asv, selectedVerses: verses)
        model.openReference(target)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        #expect(model.isRestoringNavigation)
        #expect(model.selectedVerses.isEmpty)
        #expect(await repository.saveAttempts.isEmpty)
        await repository.releaseNextLoad(.success(try savedRecord()))
        await load.value
        await model._waitForPendingPersist()

        #expect(model.position == john)
        #expect(model.translation == .asv)
        #expect(model.selectedVerses == verses)
        #expect(model.pendingScrollVerse == verses.min())
        let saved = try #require(await repository.currentRecord())
        #expect(history(saved).entries == [genesis, romans, john])
        #expect(saved.translationId == "ASV")
        // Every persisted snapshot pairs the final destination with its translation/history.
        #expect(await repository.saveAttempts.allSatisfy {
            $0.bookId == "JHN" && $0.translationId == "ASV" && history($0).current == john
        })
    }

    @Test("handoffs queued during retry apply exact selection after provisional-state cleanup", arguments: [Set<Int>(), [1, 3]])
    func handoffDuringRetry(verses: Set<Int>) async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeModel(repository)
        await failInitialRestore(model, repository: repository)
        model.selectChapter(bookId: john.bookId, chapterNumber: john.chapterNumber)
        model.toggleVerse(16)
        let retry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        let psalm = BiblePosition(bookId: "PSA", chapterNumber: 23)
        model.openReference(BibleReaderReference(position: psalm, translation: .web, selectedVerses: verses))
        #expect(model.position == john)
        await repository.releaseNextLoad(.success(try savedRecord()))
        await retry.value

        #expect(model.position == psalm)
        #expect(model.translation == .web)
        #expect(model.selectedVerses == verses)
        #expect(model.pendingScrollVerse == verses.min())
        let saved = try #require(await repository.currentRecord())
        #expect(history(saved).entries == [genesis, romans, john, psalm])
        #expect(saved.translationId == "WEB")
    }

    @Test("an already-applied provisional handoff retains translation and history while retry clears selection")
    func handoffBeforeRetry() async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeModel(repository)
        await failInitialRestore(model, repository: repository)
        model.openReference(BibleReaderReference(position: john, translation: .web, selectedVerses: [16, 18]))
        #expect(model.selectedVerses == [16, 18])
        #expect(await repository.saveAttempts.isEmpty)
        let retry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        await repository.releaseNextLoad(.success(try savedRecord()))
        await retry.value

        #expect(model.position == john)
        #expect(model.translation == .web)
        // Main intentionally clears already-applied provisional study state on recovery.
        #expect(model.selectedVerses.isEmpty)
        #expect(!model.isActionSheetPresented)
        let saved = try #require(await repository.currentRecord())
        #expect(history(saved).entries == [genesis, romans, john])
        #expect(saved.translationId == "WEB")
    }

    @Test("same-chapter exact handoffs retain the forward branch and add no visit", arguments: [Set<Int>(), [28, 30]])
    func sameChapterHandoff(verses: Set<Int>) async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeModel(repository)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.success(try savedRecord()))
        await load.value
        model.selectChapter(bookId: john.bookId, chapterNumber: john.chapterNumber)
        model.goBack()
        model.openReference(BibleReaderReference(position: romans, translation: .asv, selectedVerses: verses))
        await model._waitForPendingPersist()

        #expect(model.selectedVerses == verses)
        #expect(model.forwardDestination == john)
        let saved = try #require(await repository.currentRecord())
        #expect(history(saved).entries == [genesis, romans, john])
        #expect(history(saved).currentIndex == 1)
        #expect(saved.translationId == "ASV")
    }

    @Test("queued public ranges use the translation active at execution and bound huge ends")
    func rangeUsesRestoredTranslation() async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeModel(repository)
        model.openReference(bookId: "JHN", chapterNumber: 3, verseStart: 35, verseEnd: Int.max)
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.success(try savedRecord()))
        await load.value
        #expect(model.translation == .bsb)
        #expect(model.selectedVerses == [35, 36])
        #expect(model.pendingScrollVerse == 35)
    }

    @Test("later explicit translation wins over an exact intent drained after failed restoration")
    func laterTranslationSurvivesRetry() async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = makeModel(repository)
        model.openReference(BibleReaderReference(position: john, translation: .web, selectedVerses: [16, 18]))
        model.selectTranslation(.asv)
        await failInitialRestore(model, repository: repository)
        let retry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        await repository.releaseNextLoad(.success(try savedRecord()))
        await retry.value
        #expect(model.position == john)
        #expect(model.translation == .asv)
        #expect(await repository.currentRecord()?.translationId == "ASV")
    }

    private func makeModel(_ repository: GatedBibleReadingPositionRepository) -> BibleScreenViewModel {
        BibleScreenViewModel(textLoader: BundledBibleTextLoader(), positionRepository: repository,
                             narration: NarrationController(service: FakeNarrationService()))
    }

    private func failInitialRestore(_ model: BibleScreenViewModel, repository: GatedBibleReadingPositionRepository) async {
        let load = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await load.value
    }

    private func savedRecord() throws -> BibleReadingPositionRecord {
        var history = BibleNavigationHistory(initialPosition: genesis)
        history.visit(romans)
        return BibleReadingPositionRecord(bookId: romans.bookId, chapterNumber: romans.chapterNumber,
                                          translationId: "BSB", updatedAt: .distantPast,
                                          navigationHistoryJSON: try BibleNavigationHistoryPayload.encode(history))
    }

    private func history(_ record: BibleReadingPositionRecord) -> BibleNavigationHistory {
        BibleNavigationHistoryPayload.restore(from: record.navigationHistoryJSON,
                                               position: BiblePosition(bookId: record.bookId, chapterNumber: record.chapterNumber),
                                               catalog: .standard)
    }
}
