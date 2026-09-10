import Core
import Foundation
import Testing
@testable import Bible

/// Verifies one-time restoration and navigation winning asynchronous startup races.
@Suite("Bible reader initialization")
@MainActor
struct BibleReaderInitializationTests {
    private let saved = BibleReadingPositionRecord(
        bookId: "ROM", chapterNumber: 8, translationId: "BSB", updatedAt: Date(timeIntervalSince1970: 1)
    )

    @Test("a reader without saved state retains its injected translation")
    func initialTranslation() async {
        let model = BibleScreenViewModel(textLoader: BundledBibleTextLoader(), initialTranslation: .asv)
        await model.load()
        #expect(model.translation == .asv)
        #expect(model.chapter != nil)
    }

    @Test("concurrent and repeated loads await one restore and its complete history repair")
    func concurrentLoads() async {
        let repository = GatedReadingPositionRepository(record: saved)
        let model = makeModel(repository: repository)
        let first = Task { await model.load() }
        await repository.waitUntilLoadStarts()
        let secondStarted = AsyncStream<Void>.makeStream()
        let second = Task {
            secondStarted.continuation.yield(())
            await model.load()
            return model.position
        }
        var starts = secondStarted.stream.makeAsyncIterator()
        _ = await starts.next()
        await repository.releaseLoad()
        await first.value
        #expect(await second.value == BiblePosition(bookId: "ROM", chapterNumber: 8))
        await model.load()
        #expect(await repository.loads == 1)
        await model._waitForPendingPersist()
        #expect(await repository.writes.count == 1)
        #expect(model.translation == .bsb)
    }

    @Test("an explicit handoff before the first mount survives restoration and appends one visit")
    func handoffBeforeFirstMount() async {
        let repository = GatedReadingPositionRepository(record: saved, isGated: false)
        let model = makeModel(repository: repository)
        let target = BibleReaderReference(
            position: BiblePosition(bookId: "JHN", chapterNumber: 3),
            translation: .asv, selectedVerses: [16, 18]
        )
        model.openReference(target)
        await model.load()
        await model._waitForPendingPersist()
        #expect(model.position == target.position)
        #expect(model.translation == .asv)
        #expect(model.selectedVerses == [16, 18])
        #expect(model.pendingScrollVerse == 16)
        #expect(!model.isActionSheetPresented)
        #expect(model.backDestination == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(await repository.writes.allSatisfy { $0.bookId == "JHN" && $0.translationId == "ASV" })
    }

    @Test(arguments: [false, true])
    func navigationWinsPendingRestore(changeTranslation: Bool) async {
        let repository = GatedReadingPositionRepository(record: saved)
        let model = makeModel(repository: repository)
        let loading = Task { await model.load() }
        await repository.waitUntilLoadStarts()
        if changeTranslation {
            model.selectTranslation(.asv)
        } else {
            model.openReference(bookId: "JHN", chapterNumber: 3, verseStart: nil, verseEnd: nil)
        }
        let expectedPosition = changeTranslation ? BiblePosition(bookId: "ROM", chapterNumber: 8)
            : BiblePosition(bookId: "JHN", chapterNumber: 3)
        let expectedTranslation: BibleTranslation = changeTranslation ? .asv : .bsb
        await repository.releaseLoad()
        await loading.value
        #expect(model.position == expectedPosition)
        #expect(model.translation == expectedTranslation)
    }

    @Test("applet attachment restores translation before accepting a handoff")
    func appletRestoresBeforeInbox() async {
        let repository = GatedReadingPositionRepository(record: saved, isGated: false)
        let model = makeModel(repository: repository)
        let applet = BibleApplet(viewModel: model)
        let bus = SuperEventBus()
        await applet.attach(to: bus)
        #expect(model.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(model.translation == .bsb)
        let target = BibleReaderReference(
            position: BiblePosition(bookId: "JHN", chapterNumber: 3), translation: .web, selectedVerses: [16, 18]
        )
        await withCheckedContinuation { continuation in
            applet._referenceInbox._onNextEvent { continuation.resume() }
            Task { await bus.publish(.openRecord(reference: target.recordReference)) }
        }
        await model.load()
        #expect(model.position == target.position)
        #expect(model.selectedVerses == [16, 18])
        #expect(model.translation == .web)
        #expect(!model.isActionSheetPresented)
    }

    @Test("a range extending to Int.max selects only loaded verses")
    func hugeRangeIsBoundedByChapter() async {
        let model = makeModel()
        await model.load()
        model.openReference(bookId: "JHN", chapterNumber: 3, verseStart: 35, verseEnd: Int.max)
        #expect(model.selectedVerses == [35, 36])
        #expect(model.pendingScrollVerse == 35)
        model.openReference(bookId: "JHN", chapterNumber: 3, verseStart: Int.max, verseEnd: Int.max)
        #expect(model.selectedVerses.isEmpty)
        #expect(model.pendingScrollVerse == nil)
        #expect(!model.isActionSheetPresented)
    }

    @Test(arguments: [Set<Int>(), [35, 99], [99]])
    func exactSelectionIsBoundedByChapter(verses: Set<Int>) async {
        let model = makeModel()
        await model.load()
        model.openReference(BibleReaderReference(
            position: BiblePosition(bookId: "JHN", chapterNumber: 3), translation: .web, selectedVerses: verses
        ))
        #expect(model.selectedVerses == verses.intersection([35]))
        #expect(model.pendingScrollVerse == model.selectedVerses.min())
        #expect(!model.isActionSheetPresented)
    }

    private func makeModel(repository: (any BibleReadingPositionRepository)? = nil) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(), positionRepository: repository,
            clock: FixedClock(Date(timeIntervalSince1970: 2)),
            narration: NarrationController(service: FakeNarrationService())
        )
    }
}

/// A deterministic repository suspension used to exercise reader startup races.
private actor GatedReadingPositionRepository: BibleReadingPositionRepository {
    let record: BibleReadingPositionRecord
    var isGated: Bool
    private(set) var loads = 0
    private(set) var writes: [BibleReadingPositionRecord] = []
    private var started: CheckedContinuation<Void, Never>?
    private var pending: [CheckedContinuation<Void, Never>] = []

    init(record: BibleReadingPositionRecord, isGated: Bool = true) {
        self.record = record
        self.isGated = isGated
    }

    func load() async throws -> BibleReadingPositionRecord? {
        loads += 1
        started?.resume()
        started = nil
        if isGated { await withCheckedContinuation { pending.append($0) } }
        return record
    }

    func save(_ record: BibleReadingPositionRecord) async throws { writes.append(record) }

    func waitUntilLoadStarts() async {
        if loads == 0 { await withCheckedContinuation { started = $0 } }
    }

    func releaseLoad() {
        isGated = false
        let waiters = pending
        pending.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
