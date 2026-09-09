import Core
import Foundation
import Testing
@testable import Bible

@Suite("BibleScreenViewModel headless dispatch")
@MainActor
struct BibleScreenViewModelDispatchTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private final class AckedDisclaimerStore: AnnotationDisclaimerStore, @unchecked Sendable {
        private var value = true
        var isAcknowledged: Bool { value }
        func setAcknowledged(_ value: Bool) { self.value = value }
    }

    private func makeViewModel(
        bus: SuperEventBus? = nil
    ) async -> BibleScreenViewModel {
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            clock: FixedClock(now),
            idGenerator: DeterministicIDGenerator(prefix: "req-", start: 0),
            disclaimerStore: AckedDisclaimerStore(),
            initialPosition: BiblePosition(bookId: "ROM", chapterNumber: 8),
            narration: NarrationController(service: FakeNarrationService())
        )
        await viewModel.load()
        if let bus { await viewModel.attach(to: bus) }
        return viewModel
    }

    /// Subscribe in the test task before triggering publication. An async-let subscription
    /// can lose the event and hang this drain.
    private func drainNextRequest(stream: AsyncStream<SuperEvent>) async -> RecordReference {
        for await event in stream {
            if case .bibleAnnotateRequested(let reference) = event {
                return reference
            }
        }
        Issue.record("bus stream closed without a bibleAnnotateRequested envelope")
        return RecordReference(
            appletID: "bible", kind: "", sourceID: "",
            displayLabel: "", citation: "", snapshot: "", id: ""
        )
    }

    /// Awaits completion processing through _onNextDispatchCompletion. Request envelopes
    /// are filtered by that seam and would hang here; publish those directly.
    private func publishAndAwaitDispatch(
        _ event: SuperEvent,
        on bus: SuperEventBus,
        through viewModel: BibleScreenViewModel
    ) async {
        await withCheckedContinuation { continuation in
            viewModel._onNextDispatchCompletion {
                continuation.resume()
            }
            Task {
                await bus.publish(event)
            }
        }
    }

    @Test("a generation trigger publishes bibleAnnotateRequested and marks the target running")
    func triggerPublishesAndTracks() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let reference = await drainNextRequest(stream: stream)

        #expect(reference.appletID == "bible")
        #expect(reference.kind == "chapter")
        #expect(reference.sourceID == spec.id)
        #expect(reference.displayLabel == "Romans 8")
        #expect(viewModel.dispatchStatusByTarget[spec] == .running(requestId: reference.id))
        #expect(viewModel.presentedAnnotationTarget == spec)
        #expect(viewModel.toast == nil)
    }

    @Test("the published reference carries verbatim verse text for chapter/verse targets, none for book")
    func publishedReferenceCarriesGroundingText() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)

        let verseStream = await bus.events()
        viewModel.triggerAnnotationGeneration(
            for: .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        )
        let verseRef = await drainNextRequest(stream: verseStream)
        #expect(verseRef.snapshot.hasPrefix("28. "))
        #expect(verseRef.snapshot.contains("\n29. "))
        #expect(verseRef.snapshot.contains("\n30. "))

        // Full-book text would make the snapshot unbounded.
        let bookStream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: .book(bookId: "ROM"))
        let bookRef = await drainNextRequest(stream: bookStream)
        #expect(bookRef.snapshot.isEmpty)
    }

    @Test("a successful completion event removes the dispatch entry")
    func successRemovesEntry() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let reference = await drainNextRequest(stream: stream)

        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: reference.id, result: .success(annotationCount: 3)),
            on: bus,
            through: viewModel
        )
        #expect(viewModel.dispatchStatusByTarget[spec] == nil)
    }

    @Test("a failure completion event flips the entry to .failed with the message")
    func failureFlipsEntry() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let reference = await drainNextRequest(stream: stream)

        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: reference.id, result: .failure(message: "no key configured")),
            on: bus,
            through: viewModel
        )
        #expect(viewModel.dispatchStatusByTarget[spec] == .failed(message: "no key configured"))
    }

    @Test("clearFailedDispatchStatus clears the failed status and raises no toast")
    func regenerateFailedClearsStatusWithoutToast() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let reference = await drainNextRequest(stream: stream)
        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: reference.id, result: .failure(message: "boom")),
            on: bus,
            through: viewModel
        )
        #expect(viewModel.dispatchStatusByTarget[spec] == .failed(message: "boom"))

        viewModel.clearFailedDispatchStatus(for: spec)

        // Failed regeneration over existing cards stays silent and restores those cards.
        #expect(viewModel.toast == nil)
        #expect(viewModel.dispatchStatusByTarget[spec] == nil)
        #expect(viewModel.dispatchStatus(for: spec) == nil)
    }

    @Test("retryAnnotationGeneration re-publishes with a fresh request id")
    func retryGetsFreshId() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        let firstStream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let first = await drainNextRequest(stream: firstStream)

        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: first.id, result: .failure(message: "boom")),
            on: bus,
            through: viewModel
        )
        #expect(viewModel.dispatchStatusByTarget[spec] == .failed(message: "boom"))

        let secondStream = await bus.events()
        viewModel.retryAnnotationGeneration(for: spec)
        let second = await drainNextRequest(stream: secondStream)

        #expect(second.id != first.id)
        #expect(viewModel.dispatchStatusByTarget[spec] == .running(requestId: second.id))
    }

    @Test("a completion event for an unknown request id is ignored")
    func unknownRequestIdIsIgnored() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let request = await drainNextRequest(stream: stream)

        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: "unrelated-id", result: .success(annotationCount: 1)),
            on: bus,
            through: viewModel
        )
        #expect(viewModel.dispatchStatusByTarget[spec] == .running(requestId: request.id))
    }

    @Test("without an attached bus the dispatch falls back to the PR 3 toast")
    func noBusFallsBackToToast() async {
        let viewModel = await makeViewModel(bus: nil)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        viewModel.triggerAnnotationGeneration(for: spec)
        #expect(viewModel.toast == "Annotation generation ships in a later update.")
        #expect(viewModel.dispatchStatusByTarget[spec] == nil)
        #expect(viewModel.presentedAnnotationTarget == nil)
    }
}
