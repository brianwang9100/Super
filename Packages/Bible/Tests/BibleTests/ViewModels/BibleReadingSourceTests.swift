import Core
import Foundation
import Testing
@testable import Bible

@Suite("Bible reading sources")
@MainActor
struct BibleReadingSourceTests {
    // This store is used only on the suite's main actor.
    private final class DisclaimerStore: AnnotationDisclaimerStore, @unchecked Sendable {
        var isAcknowledged = false
        func setAcknowledged(_ value: Bool) { isAcknowledged = value }
    }

    private func reader(repository: (any BibleReadingPositionRepository)? = nil,
                        service: FakeNarrationService = FakeNarrationService()) -> BibleScreenViewModel {
        BibleScreenViewModel(textLoader: BundledBibleTextLoader(), positionRepository: repository,
                             clock: FixedClock(Date(timeIntervalSince1970: 1)),
                             disclaimerStore: DisclaimerStore(),
                             narration: NarrationController(service: service))
    }

    @Test("Natural pages preserve source selection and narration across chapter restore and history")
    func naturalPageRoundTrip() async throws {
        let repository = GRDBBibleReadingPositionRepository(database: try BibleDatabase.makeInMemory())
        let service = FakeNarrationService()
        let model = reader(repository: repository, service: service)
        await model.load()
        let original = try #require(model.primarySource)
        model.toggleVerse(1)
        model.startNarration()
        model.narration._simulateEvent(.started(verseNumber: 1))
        let originalUtterances = service.lastStartArgs?.utterances
        let location = BibleBookLocation(
            current: BibleTextLocator(position: .init(bookId: "1PE", chapterNumber: 3), translation: .kjv),
            spreadOrigin: BibleTextLocator(position: original.position, translation: .kjv))
        model.saveBookLocation(location)
        #expect(model.explicitNavigationGeneration == 0)
        #expect(model.selectionSource == original)
        #expect(model.narrationCitation == "1 Peter 2:1")
        #expect(model.narrationVerseNumber(in: original) == 1)
        #expect(service.stopCallCount == 0)
        model.saveBookLocation(location)
        model.restartNarration()
        #expect(service.lastStartArgs?.utterances == originalUtterances)
        await model.flushNavigationPersistence()
        let restored = reader(repository: repository)
        await restored.load()
        #expect(restored.bookLocation == location)
        restored.goBack()
        #expect(restored.position == original.position)
        #expect(!restored.canGoBack)
        #expect(restored.bookLocation == nil)
        restored.goForward()
        #expect(restored.position == location.current.position)
        await restored._waitForPendingPersist()
    }

    @Test("Restoration retry keeps provisional page source and offset", arguments: [2, 3])
    func provisionalPageSurvivesRetry(chapter: Int) async throws {
        let repository = GatedBibleReadingPositionRepository()
        let model = reader(repository: repository)
        let initial = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await initial.value
        let locator = BibleTextLocator(position: .init(bookId: "1PE", chapterNumber: chapter),
                                       translation: .kjv, verseNumber: 2, utf16Offset: 10)
        let location = BibleBookLocation(current: locator, spreadOrigin: locator)
        model.saveBookLocation(location)
        let retry = Task { await model.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        await repository.releaseNextLoad(.success(.init(bookId: "JHN", chapterNumber: 3,
                                                       translationId: "WEB", updatedAt: Date())))
        await retry.value
        #expect(model.position == locator.position)
        #expect(model.translation == .kjv)
        #expect(model.bookLocation == location)
        #expect(BibleBookLocation.decode(await repository.currentRecord()?.bookLocationJSON) == location)
        model.goBack()
        #expect(model.position == .init(bookId: "JHN", chapterNumber: 3))
        await model._waitForPendingPersist()
    }

    @Test("Stopped narration keeps its replay source citation after paging")
    func stoppedNarrationCitation() async throws {
        let model = reader()
        await model.load()
        let source = try model.loadReadingSource(position: .init(bookId: "JHN", chapterNumber: 3), translation: .web)
        model.toggleVerse(16, in: source)
        model.startNarration()
        let locator = BibleTextLocator(position: .init(bookId: "1PE", chapterNumber: 3), translation: .kjv)
        model.saveBookLocation(.init(current: locator, spreadOrigin: locator))
        model.narration.stop()
        #expect(model.narrationCitation == "John 3:16 (WEB)")
    }

    @Test("Comparison source owns selection text, references, and targets")
    func secondarySelection() async throws {
        let model = reader()
        await model.load()
        let source = try model.loadReadingSource(position: .init(bookId: "JHN", chapterNumber: 3), translation: .web)
        model.toggleVerse(16, in: source)
        #expect(model.translation == .kjv)
        #expect(model.selectionCitation == "John 3:16")
        #expect(model.selectionShareText?.contains("(WEB)") == true)
        #expect(model.makeVerseReference()?.sourceID == "WEB/JHN/3/16")
        #expect(model.selectionNoteSpec == .verseRange(bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 16))
        #expect(model.selectedVerses(in: source) == [16])
        #expect(model.selectedVerses(in: try #require(model.primarySource)).isEmpty)
        model.toggleVerse(1, in: source)
        let next = try model.loadReadingSource(position: .init(bookId: "JHN", chapterNumber: 4), translation: .web)
        model.toggleVerse(1, in: next)
        #expect(model.selectedVerses == [1])
        #expect(model.selectionCitation == "John 4:1")
    }

    @Test("Comparison copy and highlights write the captured source chapter")
    func secondaryCopyAndHighlight() async throws {
        let repository = GRDBBibleHighlightRepository(database: try BibleDatabase.makeInMemory(),
                                                       ids: DeterministicIDGenerator())
        let clipboard = FakeClipboard()
        let model = BibleScreenViewModel(textLoader: BundledBibleTextLoader(),
                                        highlightRepository: repository, clipboard: clipboard)
        await model.load()
        let source = try model.loadReadingSource(position: .init(bookId: "JHN", chapterNumber: 3), translation: .web)
        model.toggleVerse(16, in: source)
        let expected = model.selectionShareText
        model.applyHighlight(.yellow)
        model.copySelection()
        await model._waitForPendingHighlightWrite()
        #expect(clipboard.lastWritten == expected)
        #expect(try await repository.activeHighlights(bookId: "JHN", chapterNumber: 3).map(\.verseNumber) == [16])
        #expect(try await repository.activeHighlights(bookId: "1PE", chapterNumber: 2).isEmpty)
    }

    @Test("Invalid persisted locations fall back to chapter", arguments: ["{", "{\"version\":99}"])
    func invalidLocation(json: String) async throws {
        let repository = GRDBBibleReadingPositionRepository(database: try BibleDatabase.makeInMemory())
        try await repository.save(.init(bookId: "JHN", chapterNumber: 3, translationId: "WEB",
                                        updatedAt: Date(), bookLocationJSON: json))
        let model = reader(repository: repository)
        await model.load()
        #expect(model.bookLocation == nil)
        #expect(model.position == .init(bookId: "JHN", chapterNumber: 3))
        await model._waitForPendingPersist()
    }

    @Test("Disclaimer captures request citation and text before selection dismissal")
    func frozenDisclaimerRequest() async throws {
        let model = reader()
        let bus = SuperEventBus()
        await model.load()
        await model.attach(to: bus)
        let stream = await bus.events()
        var iterator = stream.makeAsyncIterator()
        let source = try model.loadReadingSource(position: .init(bookId: "JHN", chapterNumber: 3), translation: .web)
        model.toggleVerse(16, in: source)
        let spec = try #require(model.selectedAnnotationRanges.first)
        let expected = BibleVerseTextFormatter.numbered(source.chapter.coalescedVerses().filter { $0.number == 16 })
        model.triggerAnnotationGeneration(for: spec, sourceTranslation: model.selectionTranslation)
        #expect(model.pendingAnnotationIntents == [spec])
        model.clearSelection()
        model.selectTranslation(.asv)
        model.acknowledgeAnnotationDisclaimer()
        guard case .bibleAnnotateRequested(let request) = await iterator.next() else {
            Issue.record("Expected annotation request")
            return
        }
        #expect(request.citation == "John 3:16 (WEB)")
        #expect(request.snapshot == expected)
        await withCheckedContinuation { continuation in
            model._onNextDispatchCompletion { continuation.resume() }
            Task { await bus.publish(.bibleAnnotateCompleted(requestId: request.id, result: .failure(message: "retry"))) }
        }
        _ = await iterator.next()
        model.retryAnnotationGeneration(for: spec)
        guard case .bibleAnnotateRequested(let retry) = await iterator.next() else {
            Issue.record("Expected retry request")
            return
        }
        #expect(retry.id != request.id)
        #expect(retry.citation == request.citation)
        #expect(retry.snapshot == request.snapshot)
    }

    @Test("Regenerating a primary annotation ignores an unrelated secondary selection")
    func regenerationKeepsPresentedSource() async throws {
        let model = reader()
        await model.load()
        let primary = try #require(model.primarySource)
        let secondary = try model.loadReadingSource(position: primary.position, translation: .web)
        model.toggleVerse(1, in: secondary)
        let spec = BibleAnnotationTargetSpec.verseRange(bookId: primary.position.bookId,
            chapterNumber: primary.position.chapterNumber, verseStart: 1, verseEnd: 1)
        model.presentAnnotationSheet(for: spec, sourceTranslation: primary.translation)
        model.triggerAnnotationGeneration(for: spec)
        #expect(model.annotationVerseText(for: spec) == primary.chapter.coalescedVerses().first?.text)
    }

    @Test("Restart after changing translation begins the newly visible chapter")
    func narrationRestartAfterNavigation() async throws {
        let service = FakeNarrationService()
        let model = reader(service: service)
        await model.load()
        model.startNarration()
        model.selectTranslation(.web)
        let generation = model.narrationSessionGeneration
        model.restartNarration()
        #expect(model.narrationSource == model.primarySource)
        #expect(model.narrationSessionGeneration == generation + 1)
        #expect(service.lastStartArgs?.utterances.first?.text == model.chapter?.coalescedVerses().first?.text)
        model.narration.stop()
        model.restartNarration()
        #expect(model.narrationSessionGeneration == generation + 2)
    }

    @Test("Annotation passage translation survives clearing and navigation")
    func frozenAnnotationTranslation() async throws {
        let model = reader()
        await model.load()
        let source = try model.loadReadingSource(position: .init(bookId: "JHN", chapterNumber: 3), translation: .web)
        model.toggleVerse(16, in: source)
        let spec = try #require(model.selectedAnnotationRanges.first)
        let expected = source.chapter.coalescedVerses().first { $0.number == 16 }?.text
        model.triggerAnnotationGeneration(for: spec, sourceTranslation: model.selectionTranslation)
        model.clearSelection()
        model.selectTranslation(.asv)
        #expect(model.annotationVerseText(for: spec) == expected)
        model.acknowledgeAnnotationDisclaimer()
        model.retryAnnotationGeneration(for: spec)
        #expect(model.annotationVerseText(for: spec) == expected)
    }
}
