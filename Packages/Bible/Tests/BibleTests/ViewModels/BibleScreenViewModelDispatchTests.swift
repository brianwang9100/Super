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

    @Test("the published reference carries verbatim verse text for chapter/verse targets, none for book")
    func publishedReferenceCarriesGroundingText() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)

        // Verse-range target → the exact numbered text for that range.
        let verseStream = await bus.events()
        viewModel.triggerAnnotationGeneration(
            for: .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        )
        let verseRef = await drainNextRequest(stream: verseStream)
        #expect(verseRef.snapshot.hasPrefix("28. "))
        #expect(verseRef.snapshot.contains("\n29. "))
        #expect(verseRef.snapshot.contains("\n30. "))

        // Whole-book target → no snapshot (the full book would be enormous).
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

        viewModel.clearFailedDispatchStatus(for: spec)

        // No toast: a regenerate that fails over present cards is silent —
        // the previous cards stay on screen and speak for themselves.
        #expect(viewModel.toast == nil)
        // Status cleared so the sheet keeps showing the still-present
        // previous cards and never flips to the inline error state.
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

    @Test("retriggering a running target reopens the same request without allocating another id")
    func runningTargetIsDeduplicated() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let first = await drainNextRequest(stream: stream)
        viewModel.dismissAnnotationSheet()
        viewModel.triggerAnnotationGeneration(for: spec)
        #expect(viewModel.presentedAnnotationTarget == spec)
        #expect(viewModel.dispatchStatus(for: spec) == .running(requestId: first.id))
        let other = BibleAnnotationTargetSpec.book(bookId: "ROM")
        viewModel.triggerAnnotationGeneration(for: other)
        let next = await drainNextRequest(stream: stream)
        #expect(next.sourceID == other.id)
        #expect(next.id == "req-2")
    }

    private func progress(_ text: String, requestID: String, bus: SuperEventBus, viewModel: BibleScreenViewModel) async {
        await withCheckedContinuation { continuation in
            viewModel._onNextDispatchProgress { continuation.resume() }
            Task { await bus.publish(.bibleAnnotateProgress(requestId: requestID, text: text)) }
        }
    }

    @Test("progress survives dismiss and reopen and remains isolated by target")
    func progressIsRetainedByTarget() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let firstSpec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        let secondSpec = BibleAnnotationTargetSpec.book(bookId: "ROM")
        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: firstSpec)
        let first = await drainNextRequest(stream: stream)
        viewModel.triggerAnnotationGeneration(for: secondSpec)
        let second = await drainNextRequest(stream: stream)
        await progress("First", requestID: first.id, bus: bus, viewModel: viewModel)
        await progress("Second", requestID: second.id, bus: bus, viewModel: viewModel)
        viewModel.dismissAnnotationSheet()
        viewModel.presentAnnotationSheet(for: firstSpec)
        #expect(viewModel.annotationDraft(for: firstSpec)?.text == "First")
        #expect(viewModel.annotationDraft(for: secondSpec)?.text == "Second")
        #expect(viewModel.annotationDraft(for: firstSpec)?.isComplete == false)
        await progress("First complete paragraph", requestID: first.id, bus: bus, viewModel: viewModel)
        #expect(viewModel.annotationDraft(for: firstSpec)?.text == "First complete paragraph")
    }

    @Test("failed partial text survives and retry rejects old progress completion and cleanup")
    func retryRejectsStaleEvents() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let first = await drainNextRequest(stream: stream)
        await progress("Partial", requestID: first.id, bus: bus, viewModel: viewModel)
        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: first.id, result: .failure(message: "Interrupted")),
            on: bus, through: viewModel
        )
        #expect(viewModel.annotationDraft(for: spec)?.text == "Partial")
        viewModel.retryAnnotationGeneration(for: spec)
        let retry = await drainNextRequest(stream: stream)
        #expect(viewModel.annotationDraft(for: spec) == .init(requestID: retry.id, text: "", isComplete: false))
        await progress("Late", requestID: first.id, bus: bus, viewModel: viewModel)
        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: first.id, result: .success(annotationCount: 1)),
            on: bus, through: viewModel
        )
        viewModel.clearAnnotationDraft(for: spec, requestID: first.id)
        viewModel.clearAnnotationDraft(for: spec, requestID: retry.id)
        viewModel.clearFailedDispatchStatus(for: spec)
        #expect(viewModel.annotationDraft(for: spec) == .init(requestID: retry.id, text: "", isComplete: false))
        #expect(viewModel.dispatchStatus(for: spec) == .running(requestId: retry.id))
    }

    @Test("success retains final text until a matching settled draft acknowledgement")
    func successRetainsBridge() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.book(bookId: "ROM")
        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let request = await drainNextRequest(stream: stream)
        await progress("Final", requestID: request.id, bus: bus, viewModel: viewModel)
        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: request.id, result: .success(annotationCount: 1)),
            on: bus, through: viewModel
        )
        #expect(viewModel.annotationDraft(for: spec) == .init(requestID: request.id, text: "Final", isComplete: true))
        #expect(viewModel.dispatchStatus(for: spec) == nil)
        await progress("Late", requestID: request.id, bus: bus, viewModel: viewModel)
        #expect(viewModel.annotationDraft(for: spec)?.text == "Final")
        viewModel.clearAnnotationDraft(for: spec, requestID: "unrelated")
        #expect(viewModel.annotationDraft(for: spec) != nil)
        viewModel.clearAnnotationDraft(for: spec, requestID: request.id)
        #expect(viewModel.annotationDraft(for: spec) == nil)
    }

    @Test("returning to saved content clears only the settled failed request")
    func clearFailureDraft() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        let spec = BibleAnnotationTargetSpec.book(bookId: "ROM")
        let stream = await bus.events()
        viewModel.triggerAnnotationGeneration(for: spec)
        let request = await drainNextRequest(stream: stream)
        await publishAndAwaitDispatch(
            .bibleAnnotateCompleted(requestId: request.id, result: .failure(message: "Interrupted")),
            on: bus, through: viewModel
        )
        viewModel.clearAnnotationDraft(for: spec, requestID: "unrelated")
        #expect(viewModel.dispatchStatus(for: spec) == .failed(message: "Interrupted"))
        viewModel.clearAnnotationDraft(for: spec, requestID: request.id)
        #expect(viewModel.annotationDraft(for: spec) == nil)
        #expect(viewModel.dispatchStatus(for: spec) == nil)
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
