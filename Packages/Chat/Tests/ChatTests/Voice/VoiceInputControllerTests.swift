import Core
import Foundation
import Testing
@testable import Chat

@Suite("VoiceInputController")
@MainActor
struct VoiceInputControllerTests {
    @Test("toggle starts capture and stop synchronously releases it")
    func captureLifecycle() async {
        let service = FakeVoiceInputService()
        let activity = AudioActivity()
        let controller = VoiceInputController(service: service, audioActivity: activity)
        await controller.toggle()
        #expect(controller.state == .listening)
        #expect(service.isCapturing)
        #expect(activity.isCapturing)
        await controller.toggle()
        #expect(controller.state == .idle)
        #expect(!service.isCapturing)
        #expect(!activity.isCapturing)
    }

    @Test("permission denial never starts capture")
    func permissionDenied() async {
        let service = FakeVoiceInputService()
        service.permissionStatus = .denied
        let controller = VoiceInputController(service: service)
        await controller.toggle()
        #expect(controller.state == .denied)
        #expect(service.startCallCount == 0)
    }

    @Test("missing on-device model starts unavailable and can recover")
    func availability() async {
        let service = FakeVoiceInputService()
        service.isAvailableValue = false
        let controller = VoiceInputController(service: service)
        #expect(controller.state == .unavailable)
        await controller.toggle()
        #expect(service.startCallCount == 0)
        service.isAvailableValue = true
        await controller.toggle()
        #expect(controller.state == .listening)
    }

    @Test("each pause publishes only its phrase and clears only the preview")
    func phrasesAppendOnce() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var updates = controller.updates().makeAsyncIterator()
        #expect(await updates.next()?.appendedText == "")
        await controller.toggle()
        #expect(await updates.next()?.state == .listening)
        service.emit(.partial("hel"))
        #expect(await updates.next()?.preview == "hel")
        service.emit(.partial("hello"))
        #expect(await updates.next()?.preview == "hello")
        service.emit(.utterance("Hello."))
        let first = await updates.next()
        #expect(first?.appendedText == "Hello.")
        #expect(first?.preview == "")
        #expect(first?.state == .listening)
        service.emit(.partial("world"))
        #expect(await updates.next()?.preview == "world")
        service.emit(.utterance("world"))
        #expect(await updates.next()?.appendedText == "world")
        controller.stop()
        #expect(await updates.next()?.state == .stopping)
        let stopped = await updates.next()
        #expect(stopped?.appendedText == "")
        #expect(stopped?.state == .idle)
    }

    @Test("all terminal paths preserve the pending phrase once", arguments: [
        VoiceInputError.silenceTimeout, .recognizerFailed("boom"),
        .audioEngineFailed("audio"), .permissionDenied, .unavailable
    ])
    func errorsPreserveSpeech(error: VoiceInputError) async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var updates = controller.updates().makeAsyncIterator()
        _ = await updates.next()
        await controller.toggle()
        _ = await updates.next()
        service.emit(.partial("last words"))
        _ = await updates.next()
        service.failNext(with: error)
        let terminal = await updates.next()
        #expect(terminal?.appendedText == "last words")
        #expect(terminal?.preview == "")
        #expect(terminal?.state != .listening)
        #expect(controller.state == terminal?.state)
        let revision = controller.revision
        controller.stop()
        #expect(controller.revision == revision)
    }

    @Test("empty final commits the last nonempty partial")
    func emptyFinal() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var updates = controller.updates().makeAsyncIterator()
        _ = await updates.next()
        await controller.toggle()
        _ = await updates.next()
        service.emit(.partial("hello"))
        _ = await updates.next()
        service.emit(.partial(""))
        #expect(await updates.next()?.preview == "hello")
        service.emit(.final(""))
        #expect(await updates.next()?.appendedText == "hello")
        #expect(controller.state == .idle)
    }

    @Test("clean stream end and explicit stop flush speech", arguments: [true, false])
    func stopFlushes(cleanEnd: Bool) async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var updates = controller.updates().makeAsyncIterator()
        _ = await updates.next()
        await controller.toggle()
        _ = await updates.next()
        service.emit(.partial("hello"))
        _ = await updates.next()
        if cleanEnd {
            service.finish()
        } else {
            controller.stop()
            #expect(await updates.next()?.state == .stopping)
        }
        let terminal = await updates.next()
        #expect(terminal?.appendedText == "hello")
        #expect(terminal?.state == .idle)
        #expect(!service.isCapturing)
    }

    @Test("new subscribers see the preview but do not replay completed phrases")
    func lateSubscription() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var processed = controller._observeProcessedEvents().makeAsyncIterator()
        await controller.toggle()
        service.emit(.utterance("already delivered"))
        await processed.next()
        service.emit(.partial("pending"))
        await processed.next()
        var updates = controller.updates().makeAsyncIterator()
        let initial = await updates.next()
        #expect(initial?.appendedText == "")
        #expect(initial?.preview == "pending")
        controller.stop()
        #expect(await updates.next()?.state == .stopping)
        #expect(await updates.next()?.appendedText == "pending")
    }

    @Test("buffered phrases survive stop and restart without old callbacks corrupting capture")
    func restartFencesOldStream() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var processed = controller._observeProcessedEvents().makeAsyncIterator()
        var updates = controller.updates().makeAsyncIterator()
        await controller.toggle()
        service.emit(.utterance("yes"))
        await processed.next()
        controller.stop()
        await controller.toggle()
        service.emit(.utterance("yes"))
        await processed.next()
        #expect(controller.state == .listening)
        #expect(service.isCapturing)
        controller.stop()
        await controller._waitForPendingStop()
        let finalRevision = controller.revision
        var phrases: [String] = []
        while let update = await updates.next() {
            if !update.appendedText.isEmpty { phrases.append(update.appendedText) }
            if update.revision == finalRevision { break }
        }
        #expect(phrases == ["yes", "yes"])
    }

    @Test("stop drains recognition events already queued by the service")
    func stopDrainsServiceBuffer() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var updates = controller.updates().makeAsyncIterator()
        _ = await updates.next()
        await controller.toggle()
        _ = await updates.next()
        service.emit(.partial("first"))
        _ = await updates.next()
        service.emit(.utterance("first complete"))
        service.emit(.partial("second"))
        controller.stop()
        #expect(!service.isCapturing)
        var phrases: [String] = []
        while let update = await updates.next() {
            if !update.appendedText.isEmpty { phrases.append(update.appendedText) }
            if update.state == .idle { break }
        }
        #expect(phrases == ["first complete", "second"])
    }

    @Test("a later stop invalidates a restart waiting for the old stream to drain")
    func stopInvalidatesPendingRestart() async {
        let service = FakeVoiceInputService()
        service.delayStopCompletion()
        let controller = VoiceInputController(service: service)
        await controller.toggle()
        controller.stop()
        #expect(controller.state == .stopping)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let restarting = Task { @MainActor in
            signal.yield(())
            // Same-actor synchronous prefix enters the drain wait before the
            // entry signal can resume the test on this actor.
            await controller.toggle()
        }
        var entry = entered.makeAsyncIterator()
        await entry.next()
        controller.stop()
        service.finish()
        await restarting.value
        #expect(controller.state == .idle)
        #expect(service.startCallCount == 1)
        #expect(!service.isCapturing)
    }

    @Test("terminal event fences already-buffered later events")
    func finalIsTerminal() async {
        let service = FakeVoiceInputService()
        let controller = VoiceInputController(service: service)
        var updates = controller.updates().makeAsyncIterator()
        _ = await updates.next()
        await controller.toggle()
        _ = await updates.next()
        service.emit(.final("first"))
        service.emit(.final("stale"))
        service.emit(.partial("stale preview"))
        #expect(await updates.next()?.appendedText == "first")
        await controller.toggle()
        #expect(await updates.next()?.state == .listening)
        service.emit(.final("second"))
        #expect(await updates.next()?.appendedText == "second")
    }

    @Test("rapid toggles cannot double-start a pending permission request")
    func rapidToggle() async {
        let service = FakeVoiceInputService()
        let gate = service.gatePermissions()
        let controller = VoiceInputController(service: service)
        async let winner: Void = controller.toggle()
        await gate.waitUntilEntered()
        await controller.toggle()
        #expect(service.startCallCount == 0)
        gate.release()
        await winner
        #expect(service.startCallCount == 1)
    }
}
