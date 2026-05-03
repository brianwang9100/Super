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
        await controller.toggle()

        service.emit(.partial("hel"))
        await yieldUntil { controller.partialTranscript == "hel" }
        service.emit(.partial("hello"))
        await yieldUntil { controller.partialTranscript == "hello" }
        service.emit(.partial("hello there"))
        await yieldUntil { controller.partialTranscript == "hello there" }

        #expect(controller.partialTranscript == "hello there")
        #expect(controller.state == .listening)
    }

    @Test("final event commits via callback, clears partial, returns to idle")
    func finalEventCommitsViaCallback() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        let recorded = TranscriptRecorder()
        controller.onFinalTranscript = { text in recorded.append(text) }

        await controller.toggle()
        service.emit(.partial("hel"))
        service.emit(.final("hello world"))
        await yieldUntil { controller.state == .idle }

        #expect(recorded.values == ["hello world"])
        #expect(controller.partialTranscript == "")
        #expect(controller.state == .idle)
    }

    @Test("stream failure sets failed state and clears partial")
    func streamFailureSetsFailedState() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)

        await controller.toggle()
        service.emit(.partial("typing"))
        await yieldUntil { controller.partialTranscript == "typing" }
        service.failNext(with: .recognizerFailed("boom"))
        await yieldUntil {
            if case .failed = controller.state { return true }
            return false
        }

        #expect(controller.state == .failed("boom"))
        #expect(controller.partialTranscript == "")
    }

    @Test("silence timeout commits the most recent partial as a final transcript")
    func silenceTimeoutCommitsLastPartial() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        let recorded = TranscriptRecorder()
        controller.onFinalTranscript = { text in recorded.append(text) }

        await controller.toggle()
        service.emit(.partial("hello"))
        await yieldUntil { controller.partialTranscript == "hello" }
        service.failNext(with: .silenceTimeout)
        await yieldUntil { controller.state == .idle }

        #expect(recorded.values == ["hello"])
        #expect(controller.state == .idle)
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

        async let first: Void = controller.toggle()
        async let second: Void = controller.toggle()

        // Yield enough that both toggles enter `requestPermissions`
        // and the second one has hit the `isStarting` guard.
        for _ in 0..<10 { await Task.yield() }

        gate.release()
        _ = await (first, second)

        #expect(service.startCallCount == 1)
        #expect(controller.state == .listening)
    }

    /// Yield to the @MainActor task pool until `condition()` returns
    /// true or the polling cap is reached.
    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
        }
    }
}

/// `@MainActor`-bound recorder so we can capture every onFinalTranscript
/// fire from inside the test body without sprinkling `Task` hops.
@MainActor
private final class TranscriptRecorder {
    private(set) var values: [String] = []
    func append(_ text: String) { values.append(text) }
}
