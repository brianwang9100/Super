import Foundation
import Testing
@testable import Chat

/// Tests for ``VoiceInputController``'s state machine, partial/final
/// transcript plumbing, and rapid-toggle guard. Drives the controller
/// directly with a ``FakeVoiceInputService`` so the assertions don't
/// depend on standing up `SFSpeechRecognizer` (SFSpeech = Apple's
/// Speech-recognition framework) or a real microphone.
@Suite("VoiceInputController")
@MainActor
struct VoiceInputControllerTests {
    @Test("toggle starts listening when permissions are granted")
    func toggleStartsListeningWhenPermissionsGranted() async {
        let service = FakeVoiceInputService()
        service.permissionStatus = .granted
        service.isAvailableValue = true
        let controller = VoiceInputController(service: service)

        #expect(controller.state == .idle)
        await controller.toggle()

        #expect(controller.state == .listening)
        #expect(service.startCallCount == 1)
    }

    @Test("toggle stops listening on the second call")
    func toggleStopsListeningOnSecondCall() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        await controller.toggle()
        #expect(controller.state == .listening)

        await controller.toggle()

        #expect(controller.state == .idle)
        // The controller's stop() commits whatever partial existed
        // (empty here) so no final-transcript callback fires with a
        // non-empty string. We only assert state.
    }

    @Test("permission denied sets the .denied state without starting a stream")
    func permissionDeniedSetsDeniedState() async {
        let service = FakeVoiceInputService()
        service.permissionStatus = .denied
        let controller = VoiceInputController(service: service)

        await controller.toggle()

        #expect(controller.state == .denied)
        #expect(service.startCallCount == 0)
    }

    @Test("service unavailable boots the controller into the .unavailable state")
    func serviceUnavailableSetsUnavailableState() {
        let service = FakeVoiceInputService()
        service.isAvailableValue = false
        let controller = VoiceInputController(service: service)

        #expect(controller.state == .unavailable)
    }

    @Test("partial transcript reflects service events in order")
    func partialTranscriptReflectsServiceEvents() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var processed = controller._observeProcessedEvents().makeAsyncIterator()
        await controller.toggle()

        service.emit(.partial("hel"))
        await processed.next()
        #expect(controller.partialTranscript == "hel")
        service.emit(.partial("hello"))
        await processed.next()
        #expect(controller.partialTranscript == "hello")
        service.emit(.partial("hello there"))
        await processed.next()

        #expect(controller.partialTranscript == "hello there")
        #expect(controller.state == .listening)
    }

    @Test("final event commits via callback, clears partial, returns to idle")
    func finalEventCommitsViaCallback() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        let recorded = TranscriptRecorder()
        controller.onFinalTranscript = { text in recorded.append(text) }
        var processed = controller._observeProcessedEvents().makeAsyncIterator()

        await controller.toggle()
        service.emit(.partial("hel"))
        await processed.next()
        service.emit(.final("hello world"))
        await processed.next()

        #expect(recorded.values == ["hello world"])
        #expect(controller.partialTranscript == "")
        #expect(controller.state == .idle)
    }

    @Test("stream failure sets failed state and clears partial")
    func streamFailureSetsFailedState() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var processed = controller._observeProcessedEvents().makeAsyncIterator()

        await controller.toggle()
        service.emit(.partial("typing"))
        await processed.next()
        #expect(controller.partialTranscript == "typing")
        service.failNext(with: .recognizerFailed("boom"))
        await processed.next()

        #expect(controller.state == .failed("boom"))
        #expect(controller.partialTranscript == "")
    }

    @Test("silence timeout commits the most recent partial as a final transcript")
    func silenceTimeoutCommitsLastPartial() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        let recorded = TranscriptRecorder()
        controller.onFinalTranscript = { text in recorded.append(text) }
        var processed = controller._observeProcessedEvents().makeAsyncIterator()

        await controller.toggle()
        service.emit(.partial("hello"))
        await processed.next()
        #expect(controller.partialTranscript == "hello")
        service.failNext(with: .silenceTimeout)
        await processed.next()

        #expect(recorded.values == ["hello"])
        #expect(controller.state == .idle)
        #expect(controller.partialTranscript == "")
    }

    @Test("cross-pause accumulation: consecutive partials with no intervening .final render as a single growing transcript")
    func crossPauseAccumulationFlowsThroughAsPartials() async {
        // Documents the post-fix service contract: when Apple's
        // SFSpeechRecognizer auto-endpoints on a natural pause, the
        // service swallows the `.isFinal=true` callback, commits the
        // utterance to its internal accumulator, transparently spins
        // up the next recognition task, and continues emitting
        // `.partial(...)` events that carry the merged transcript.
        // The controller sees a single uninterrupted stream of
        // partials — no `.final` until the user actually stops (or
        // silence-timeout fires) — so a regression that accidentally
        // re-introduces a mid-session `.final` (botched merge, future
        // refactor) would break user-facing behavior even when the
        // `DictationTranscriptAccumulator` unit tests stay green.
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        let recorded = TranscriptRecorder()
        controller.onFinalTranscript = { text in recorded.append(text) }
        var processed = controller._observeProcessedEvents().makeAsyncIterator()

        await controller.toggle()
        // First utterance refines.
        service.emit(.partial("hel"))
        await processed.next()
        service.emit(.partial("hello"))
        await processed.next()
        #expect(controller.partialTranscript == "hello")

        // Pause boundary: the service's accumulator now contains
        // ["hello"] internally; the next partial carries the merged
        // committed + new-in-flight text.
        service.emit(.partial("hello world"))
        await processed.next()
        #expect(controller.partialTranscript == "hello world")

        // No `.final` has been delivered — the controller is still
        // listening and `onFinalTranscript` hasn't fired even once.
        #expect(controller.state == .listening)
        #expect(recorded.values == [])

        // User taps stop / silence-timeout fires; the accumulated
        // text commits via the normal terminal-event path.
        service.failNext(with: .silenceTimeout)
        await processed.next()

        #expect(recorded.values == ["hello world"])
        #expect(controller.partialTranscript == "")
    }

    @Test("rapid toggle inside the same task tick does not double-start the service")
    func rapidToggleDoesNotDoubleStart() async {
        let service = FakeVoiceInputService()
        // Suspend `requestPermissions` so the first toggle is still in
        // its `await` (state still `.idle`, `isStarting == true`) when
        // the second toggle arrives. This is the actual race the
        // controller's `isStarting` guard protects against — two taps
        // landing inside the same task tick before `state` flips to
        // `.listening`. Without the gate, the first toggle would
        // complete synchronously (FakeVoiceInputService returns the
        // permission status without awaiting) and the second would
        // route through the `.listening → stop()` arm instead, never
        // exercising `isStarting` at all.
        let gate = service.gatePermissions()
        let controller = VoiceInputController(service: service)

        // Launch the winning toggle and await — on an observable signal, not a
        // yield-spin — until it has set `isStarting` and parked on the gated
        // `requestPermissions`. The synchronous prefix of `toggle()` runs on
        // the serial main actor, so exactly one call sets `isStarting` before
        // suspending here.
        async let winner: Void = controller.toggle()
        await gate.waitUntilEntered()

        // The second toggle now runs with `state == .idle` and
        // `isStarting == true`, so it hits the guard and returns synchronously
        // — deterministically exercising the drop without racing the winner.
        await controller.toggle()
        #expect(service.startCallCount == 0)

        gate.release()
        await winner

        #expect(service.startCallCount == 1)
        #expect(controller.state == .listening)
    }
}

/// `@MainActor`-bound recorder so we can capture every onFinalTranscript
/// fire from inside the test body without sprinkling `Task` hops.
@MainActor
private final class TranscriptRecorder {
    private(set) var values: [String] = []
    func append(_ text: String) { values.append(text) }
}
