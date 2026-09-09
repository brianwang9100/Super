import Core
import Foundation
import Testing
@testable import Bible

/// Tests for the applet-lifetime annotation dispatcher shared by Bible readers.
@Suite("BibleAnnotationDispatchViewModel")
@MainActor
struct BibleAnnotationDispatchViewModelTests {
    private struct AckedDisclaimerStore: AnnotationDisclaimerStore, Sendable {
        var isAcknowledged: Bool { true }
        func setAcknowledged(_ value: Bool) {}
    }

    private func makeReference(id: String, spec: BibleAnnotationTargetSpec) -> RecordReference {
        RecordReference(
            appletID: BibleApplet.appletID,
            kind: "chapter",
            sourceID: spec.id,
            displayLabel: "Romans 8",
            citation: "Romans 8 (WEB)",
            snapshot: "1. Therefore...",
            id: id
        )
    }

    private func makeReader(
        dispatcher: BibleAnnotationDispatchViewModel,
        idPrefix: String
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            idGenerator: DeterministicIDGenerator(prefix: idPrefix, start: 0),
            disclaimerStore: AckedDisclaimerStore(),
            initialPosition: BiblePosition(bookId: "ROM", chapterNumber: 8),
            narration: NarrationController(service: FakeNarrationService()),
            annotationDispatchViewModel: dispatcher
        )
    }

    private func publishAndAwaitCompletion(
        _ event: SuperEvent,
        on bus: SuperEventBus,
        through dispatcher: BibleAnnotationDispatchViewModel
    ) async {
        await withCheckedContinuation { continuation in
            dispatcher._onNextCompletionProcessed {
                continuation.resume()
            }
            Task {
                await bus.publish(event)
            }
        }
    }

    private func drainRequestsThroughBarrier(
        from stream: AsyncStream<SuperEvent>,
        on bus: SuperEventBus,
        through dispatcher: BibleAnnotationDispatchViewModel
    ) async -> [RecordReference] {
        await dispatcher._waitForPendingPublish()
        await bus.publish(.sidebarOpened)

        var requests: [RecordReference] = []
        for await event in stream {
            switch event {
            case .bibleAnnotateRequested(let reference):
                requests.append(reference)
            case .sidebarOpened:
                return requests
            default:
                break
            }
        }
        Issue.record("bus stream closed before the barrier event")
        return requests
    }

    private func publishProgress(
        _ text: String,
        requestID: String,
        on bus: SuperEventBus,
        through dispatcher: BibleAnnotationDispatchViewModel
    ) async {
        await withCheckedContinuation { continuation in
            dispatcher._onNextProgressProcessed { continuation.resume() }
            Task { await bus.publish(.bibleAnnotateProgress(requestId: requestID, text: text)) }
        }
    }

    @Test("concurrent attachment installs one bus subscriber")
    func concurrentAttachmentIsIdempotent() async {
        let bus = SuperEventBus()
        let dispatcher = BibleAnnotationDispatchViewModel()

        async let first: Void = dispatcher.attach(to: bus)
        async let second: Void = dispatcher.attach(to: bus)
        _ = await (first, second)

        #expect(await bus.subscriberCount == 1)
    }

    @Test("duplicate requests share the running id and publish once")
    func duplicateRequestsShareRunningDispatch() async {
        let bus = SuperEventBus()
        let dispatcher = BibleAnnotationDispatchViewModel()
        await dispatcher.attach(to: bus)
        let stream = await bus.events()
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        let first = dispatcher.request(reference: makeReference(id: "request-1", spec: spec), for: spec)
        let duplicate = dispatcher.request(reference: makeReference(id: "request-2", spec: spec), for: spec)
        let requests = await drainRequestsThroughBarrier(from: stream, on: bus, through: dispatcher)

        #expect(first == .started(requestId: "request-1"))
        #expect(duplicate == .alreadyRunning(requestId: "request-1"))
        #expect(requests.map(\.id) == ["request-1"])
        #expect(dispatcher.status(for: spec) == .running(requestId: "request-1"))
    }

    @Test("two readers observe one running request and its matching completion")
    func readersShareRunningAndCompletionState() async {
        let bus = SuperEventBus()
        let dispatcher = BibleAnnotationDispatchViewModel()
        await dispatcher.attach(to: bus)
        let firstReader = makeReader(dispatcher: dispatcher, idPrefix: "first-")
        let secondReader = makeReader(dispatcher: dispatcher, idPrefix: "second-")
        let stream = await bus.events()
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)

        firstReader.triggerAnnotationGeneration(for: spec)
        secondReader.triggerAnnotationGeneration(for: spec)
        let requests = await drainRequestsThroughBarrier(from: stream, on: bus, through: dispatcher)
        #expect(requests.count == 1)
        guard let request = requests.first else {
            Issue.record("the shared request was not published")
            return
        }
        #expect(firstReader.dispatchStatus(for: spec) == .running(requestId: request.id))
        #expect(secondReader.dispatchStatus(for: spec) == .running(requestId: request.id))
        #expect(firstReader.presentedAnnotationTarget == spec)
        #expect(secondReader.presentedAnnotationTarget == spec)

        await publishProgress("Shared partial text", requestID: request.id, on: bus, through: dispatcher)
        let partial = BibleAnnotationDraft(requestID: request.id, text: "Shared partial text")
        #expect(firstReader.annotationDraft(for: spec) == partial)
        #expect(secondReader.annotationDraft(for: spec) == partial)
        secondReader.clearAnnotationDraft(for: spec, requestID: request.id)
        secondReader.triggerAnnotationGeneration(for: spec)
        #expect(secondReader.annotationDraft(for: spec) == partial)

        await publishAndAwaitCompletion(
            .bibleAnnotateCompleted(requestId: request.id, result: .success(annotationCount: 1)),
            on: bus,
            through: dispatcher
        )

        #expect(firstReader.dispatchStatus(for: spec) == nil)
        #expect(secondReader.dispatchStatus(for: spec) == nil)
        let completed = BibleAnnotationDraft(requestID: request.id, text: partial.text, isComplete: true)
        #expect(firstReader.annotationDraft(for: spec) == completed)
        #expect(secondReader.annotationDraft(for: spec) == completed)
        firstReader.clearAnnotationDraft(for: spec, requestID: "stale-request")
        #expect(secondReader.annotationDraft(for: spec) == completed)
        secondReader.clearAnnotationDraft(for: spec, requestID: request.id)
        #expect(firstReader.annotationDraft(for: spec) == nil)
    }

    @Test("a stale completion cannot clear a newer retry")
    func staleCompletionCannotClearRetry() async {
        let bus = SuperEventBus()
        let dispatcher = BibleAnnotationDispatchViewModel()
        await dispatcher.attach(to: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        let first = makeReference(id: "request-1", spec: spec)
        let retry = makeReference(id: "request-2", spec: spec)

        #expect(dispatcher.request(reference: first, for: spec) == .started(requestId: first.id))
        await dispatcher._waitForPendingPublish()
        await publishAndAwaitCompletion(
            .bibleAnnotateCompleted(requestId: first.id, result: .failure(message: "try again")),
            on: bus,
            through: dispatcher
        )
        #expect(dispatcher.request(reference: retry, for: spec) == .started(requestId: retry.id))
        await dispatcher._waitForPendingPublish()
        let firstReader = makeReader(dispatcher: dispatcher, idPrefix: "first-")
        let secondReader = makeReader(dispatcher: dispatcher, idPrefix: "second-")
        await publishProgress("Retry text", requestID: retry.id, on: bus, through: dispatcher)
        await publishProgress("Stale text", requestID: first.id, on: bus, through: dispatcher)
        firstReader.clearAnnotationDraft(for: spec, requestID: first.id)
        secondReader.clearAnnotationDraft(for: spec, requestID: retry.id)

        await publishAndAwaitCompletion(
            .bibleAnnotateCompleted(requestId: first.id, result: .success(annotationCount: 1)),
            on: bus,
            through: dispatcher
        )

        #expect(dispatcher.status(for: spec) == .running(requestId: retry.id))
        #expect(firstReader.annotationDraft(for: spec) == .init(requestID: retry.id, text: "Retry text"))
        #expect(secondReader.annotationDraft(for: spec) == firstReader.annotationDraft(for: spec))
    }

    @Test("releasing a preview reader preserves running and failure state")
    func readerReleasePreservesDispatchState() async {
        let bus = SuperEventBus()
        let dispatcher = BibleAnnotationDispatchViewModel()
        await dispatcher.attach(to: bus)
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        let stream = await bus.events()
        weak var releasedReader: BibleScreenViewModel?

        do {
            var preview: BibleScreenViewModel? = makeReader(dispatcher: dispatcher, idPrefix: "preview-")
            releasedReader = preview
            preview?.triggerAnnotationGeneration(for: spec)
            preview = nil
        }

        #expect(releasedReader == nil)
        let requests = await drainRequestsThroughBarrier(from: stream, on: bus, through: dispatcher)
        guard let request = requests.first else {
            Issue.record("the preview request was not published")
            return
        }
        #expect(requests.count == 1)
        #expect(dispatcher.status(for: spec) == .running(requestId: request.id))
        await publishProgress("Continued after release", requestID: request.id, on: bus, through: dispatcher)
        let reopenedReader = makeReader(dispatcher: dispatcher, idPrefix: "reopened-")
        #expect(reopenedReader.annotationDraft(for: spec)?.text == "Continued after release")
        await publishAndAwaitCompletion(
            .bibleAnnotateCompleted(requestId: request.id, result: .failure(message: "offline")),
            on: bus,
            through: dispatcher
        )
        #expect(dispatcher.status(for: spec) == .failed(message: "offline"))
        #expect(reopenedReader.annotationDraft(for: spec)?.text == "Continued after release")
    }
}
