import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `BibleScreenViewModel`'s headless-dispatch surface added in
/// PR 4 — the path that replaces the PR 3 "ships in a later update"
/// toast with a real `bibleAnnotateRequested` publish + per-target
/// dispatch tracking + retry.
///
/// Synchronization (per AGENTS.md §2 — no `Task.yield()` polling, no
/// `async let` for subscription):
///
/// - **Capturing a *published* request**: subscribe in the *test* task
///   (`let stream = await bus.events()`) *before* invoking the
///   trigger. The actor call completes synchronously w.r.t. the test
///   task, so the subscription is registered in the bus's continuations
///   dict before the view-model's fire-and-forget publish task can fan
///   out. `async let` for the subscription would re-introduce the race
///   the in-tree review feedback already flagged.
///
/// - **Waiting for a *received* completion to flip view-model state**:
///   register `viewModel._onNextDispatchCompletion` (test seam) before
///   publishing. The callback fires after the *completion* envelope
///   has been processed and the state updated — request echoes are
///   filtered out so the callback doesn't race ahead of the actual
///   completion.
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

    /// Drain `stream` until the next `bibleAnnotateRequested` envelope
    /// arrives. The caller must have subscribed to the bus
    /// synchronously in the test task before invoking the publishing
    /// action; otherwise the publish task may fan out before the
    /// subscription is registered and the stream hangs.
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

    /// Publish a *completion* `event` and await the view model's
    /// dispatch subscription processing it. Uses
    /// `_onNextDispatchCompletion` as a continuation handle so the
    /// assertion that follows sees the post-event state
    /// deterministically. Request envelopes routed through this helper
    /// will never resume the continuation (the seam filters them out)
    /// — pass them to `bus.publish` directly instead.
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
        // The PR 3 toast must NOT fire on the dispatch path —
        // user-visible feedback is the sheet, not a stub message.
        #expect(viewModel.toast == nil)
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

    @Test("presentRegenerateAnnotationFailedToast raises the copy and clears the failed status")
    func regenerateFailedToastClearsStatus() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        // Drive the target into a real `.failed` status the way a
        // regenerate-over-populated failure would.
        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let reference = await drainNextRequest(stream: stream)
        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: reference.id, result: .failure(message: "boom")),
            on: bus,
            through: viewModel
        )
        #expect(viewModel.dispatchStatusByTarget[spec] == .failed(message: "boom"))

        viewModel.presentRegenerateAnnotationFailedToast(for: spec)

        #expect(viewModel.toast == "Couldn't regenerate annotations.")
        // Status cleared so the sheet keeps showing the still-present
        // previous cards rather than the inline error state.
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
        // The running entry stays because no entry matched the
        // unknown id — and it still carries the original request id,
        // not the unrelated one.
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
