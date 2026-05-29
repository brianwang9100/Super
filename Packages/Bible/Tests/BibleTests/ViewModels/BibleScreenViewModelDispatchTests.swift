import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `BibleScreenViewModel`'s headless-dispatch surface added in
/// PR 4 — the path that replaces the PR 3 "ships in a later update"
/// toast with a real `bibleAnnotateRequested` publish + per-target
/// dispatch tracking + retry.
///
/// Synchronization (per AGENTS.md §2 — no `Task.yield()` polling):
///
/// - Capturing a *published* request: subscribe to `bus.events()`
///   synchronously before triggering. The `await bus.events()` call
///   blocks on the bus actor until the subscription is registered, so
///   the next published event is guaranteed to land in the returned
///   stream.
///
/// - Waiting for a *received* completion to flip view-model state:
///   register `viewModel._onNextDispatchEvent` (test seam) before
///   publishing. The callback fires after `handleBusEvent` runs, so
///   the post-await assertions see the post-event state.
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

    /// Subscribe to the bus synchronously, then iterate the returned
    /// stream until we see the next `bibleAnnotateRequested` envelope.
    /// The `await bus.events()` registers the subscription on the
    /// actor before this function returns, so any publish that happens
    /// after the subscription was returned is guaranteed to be
    /// delivered — no `Task.yield()` race.
    private func nextRequest(on bus: SuperEventBus) async -> RecordReference {
        let stream = await bus.events()
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

    /// Publish `event` and await the view model's dispatch
    /// subscription processing it. Uses `_onNextDispatchEvent` as a
    /// continuation handle so the assertion that follows sees the
    /// post-event state deterministically.
    private func publishAndAwaitDispatch(
        _ event: SuperEvent,
        on bus: SuperEventBus,
        through viewModel: BibleScreenViewModel
    ) async {
        await withCheckedContinuation { continuation in
            viewModel._onNextDispatchEvent {
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

        async let captured = nextRequest(on: bus)
        viewModel.triggerAnnotationGeneration(for: spec)
        let reference = await captured

        #expect(reference.appletID == "bible")
        #expect(reference.kind == "chapter")
        #expect(reference.sourceID == spec.id)
        #expect(reference.displayLabel == "Romans 8")
        #expect(viewModel.dispatchStatusByTarget[spec] == .running(requestId: reference.id))
        #expect(viewModel.presentedAnnotationTarget == spec)
        // The PR 3 toast must NOT fire on the dispatch path —
        // user-visible feedback is the sheet, not a stub message.
        #expect(viewModel.toast == nil)
    }

    @Test("a successful completion event removes the dispatch entry")
    func successRemovesEntry() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        async let captured = nextRequest(on: bus)
        viewModel.triggerAnnotationGeneration(for: spec)
        let reference = await captured

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

        async let captured = nextRequest(on: bus)
        viewModel.triggerAnnotationGeneration(for: spec)
        let reference = await captured

        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: reference.id, result: .failure(message: "no key configured")),
            on: bus,
            through: viewModel
        )
        #expect(viewModel.dispatchStatusByTarget[spec] == .failed(message: "no key configured"))
    }

    @Test("retryAnnotationGeneration re-publishes with a fresh request id")
    func retryGetsFreshId() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        async let firstCaptured = nextRequest(on: bus)
        viewModel.triggerAnnotationGeneration(for: spec)
        let first = await firstCaptured

        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: first.id, result: .failure(message: "boom")),
            on: bus,
            through: viewModel
        )
        #expect(viewModel.dispatchStatusByTarget[spec] == .failed(message: "boom"))

        async let secondCaptured = nextRequest(on: bus)
        viewModel.retryAnnotationGeneration(for: spec)
        let second = await secondCaptured

        #expect(second.id != first.id)
        #expect(viewModel.dispatchStatusByTarget[spec] == .running(requestId: second.id))
    }

    @Test("a completion event for an unknown request id is ignored")
    func unknownRequestIdIsIgnored() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        async let captured = nextRequest(on: bus)
        viewModel.triggerAnnotationGeneration(for: spec)
        _ = await captured

        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: "unrelated-id", result: .success(annotationCount: 1)),
            on: bus,
            through: viewModel
        )
        // The running entry stays because no entry matched the
        // unknown id.
        if case .running = viewModel.dispatchStatusByTarget[spec] {
            // expected
        } else {
            Issue.record("entry should still be running, got \(String(describing: viewModel.dispatchStatusByTarget[spec]))")
        }
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
