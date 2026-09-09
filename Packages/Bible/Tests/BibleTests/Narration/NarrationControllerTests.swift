import AVFoundation
import Foundation
import Testing
@testable import Bible

/// _simulateEvent applies events synchronously on MainActor; stream tests separately drain consumer tasks.
@Suite("NarrationController")
@MainActor
struct NarrationControllerTests {
    @Test("Retry resumes the failed verse within the original selection", arguments: [false, true])
    func retryPreservesFailurePosition(preparing: Bool) {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service, cloudService: service)
        controller.voice = .marin
        controller.rate = 1.5
        let queue = [4, 7, 9].map { NarrationVerseUtterance(verseNumber: $0, text: "Verse \($0)") }
        controller.start(utterances: queue)
        controller._simulateEvent(.started(verseNumber: 4))
        controller._simulateEvent(preparing ? .preparing(verseNumber: 7) : .started(verseNumber: 7))
        controller._simulateEvent(.failed(.speech(.unavailable)))
        controller.retry()
        #expect(service.lastStartArgs?.startingAt == 1)
        #expect(service.lastStartArgs?.utterances == queue)
        #expect(controller.voice == .marin)
        #expect(service.lastStartArgs?.rate == 1.5)
        #expect(controller.lastError == nil)
        controller.stop()
    }

    @Test("Stopping a failed session prevents Retry from reviving an old reader context")
    func stopClearsFailedSessionRetry() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        controller.start(utterances: [.init(verseNumber: 4, text: "Old chapter")])
        controller._simulateEvent(.started(verseNumber: 4))
        controller._simulateEvent(.failed(.speech(.unavailable)))
        // Chapter and translation navigation both stop narration before changing the reader.
        controller.stop()
        controller.retry()
        #expect(controller.lastError == nil)
        #expect(controller.state == .idle)
        #expect(service.startCallCount == 1)
    }

    @Test("initial voice discovery uses the injected service and requested locale")
    func initialVoiceUsesInjectedService() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let locale = Locale(identifier: "fr-FR")

        #expect(controller.bestAvailableVoice(locale: locale) == nil)
        #expect(service.voiceLookupLocales == [locale])
    }

    @Test("default voice preparation uses the injected service and preserves an explicit choice")
    func preparesDefaultVoiceThroughService() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        await controller.prepareDefaultVoice()
        #expect(service.voiceLookupLocales.count == 1)
        controller.voice = .marin
        await controller.prepareDefaultVoice()
        #expect(service.voiceLookupLocales.count == 1)
        #expect(controller.voice == .marin)
    }

    @Test("a fresh controller is idle with no current verse")
    func freshControllerIsIdle() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        #expect(controller.state == .idle)
        #expect(controller.currentVerseNumber == nil)
        #expect(controller.lastError == nil)
    }

    @Test("starting a session forwards utterances and lands in .speaking on the first .started event")
    func startForwardsUtterancesAndTransitionsOnStarted() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let queue = [
            NarrationVerseUtterance(verseNumber: 1, text: "alpha"),
            NarrationVerseUtterance(verseNumber: 2, text: "beta"),
        ]

        controller.start(utterances: queue)
        #expect(service.startCallCount == 1)
        #expect(service.lastStartArgs?.utterances == queue)

        controller._simulateEvent(.started(verseNumber: 1))
        #expect(controller.state == .speaking)
        #expect(controller.currentVerseNumber == 1)
    }

    @Test("walking through .started + .finishedVerse for every utterance ends at .completed → idle")
    func wholeQueueWalksToCompletedIdle() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let recorder = CompletionRecorder()
        controller.onCompletion = { recorder.record() }

        controller.start(utterances: (1...3).map {
            NarrationVerseUtterance(verseNumber: $0, text: "verse \($0)")
        })
        for verse in 1...3 {
            controller._simulateEvent(.started(verseNumber: verse))
            #expect(controller.currentVerseNumber == verse)
            controller._simulateEvent(.finishedVerse(verseNumber: verse))
        }
        controller._simulateEvent(.completed)

        #expect(controller.state == .idle)
        #expect(controller.currentVerseNumber == nil)
        #expect(recorder.firedCount == 1)
    }

    @Test("pause + resume preserves currentVerseNumber and reflects the .paused / .resumed events")
    func pauseResumePreservesCurrentVerse() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 4, text: "four"),
        ])
        controller._simulateEvent(.started(verseNumber: 4))
        #expect(controller.state == .speaking)

        controller.pause()
        #expect(service.pauseCallCount == 1)
        controller._simulateEvent(.paused)
        #expect(controller.state == .paused)
        #expect(controller.currentVerseNumber == 4)

        controller.resume()
        #expect(service.resumeCallCount == 1)
        controller._simulateEvent(.resumed)
        #expect(controller.state == .speaking)
        #expect(controller.currentVerseNumber == 4)
    }

    @Test("stop() is idempotent — calling twice yields .idle once and only one .cancelled is needed")
    func stopIsIdempotent() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let recorder = CompletionRecorder()
        controller.onCompletion = { recorder.record() }

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "x")])
        controller._simulateEvent(.started(verseNumber: 1))

        controller.stop()
        controller.stop()
        controller._simulateEvent(.cancelled)

        #expect(controller.state == .idle)
        #expect(controller.currentVerseNumber == nil)
        #expect(recorder.firedCount == 1)
    }

    @Test("skipNext forwards to the service; the next .started event updates currentVerseNumber")
    func skipNextForwardsAndStateFollowsEvents() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 1, text: "one"),
            NarrationVerseUtterance(verseNumber: 2, text: "two"),
        ])
        controller._simulateEvent(.started(verseNumber: 1))

        controller.skipNext()
        #expect(service.skipForwardCallCount == 1)
        controller._simulateEvent(.finishedVerse(verseNumber: 1))
        controller._simulateEvent(.started(verseNumber: 2))
        #expect(controller.currentVerseNumber == 2)
    }

    @Test("skipNext on the last utterance completes the session through .completed")
    func skipNextAtLastUtteranceCompletes() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let recorder = CompletionRecorder()
        controller.onCompletion = { recorder.record() }

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 9, text: "last")])
        controller._simulateEvent(.started(verseNumber: 9))

        controller.skipNext()
        controller._simulateEvent(.completed)

        #expect(controller.state == .idle)
        #expect(recorder.firedCount == 1)
    }

    @Test("a single skipPrevious tap restarts the current verse")
    func skipPreviousSingleTapRestartsCurrentVerse() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 2, text: "two")])
        controller._simulateEvent(.started(verseNumber: 2))

        controller.skipPrevious()
        #expect(service.skipBackwardCallCount == 1)
        #expect(service.skipToPreviousVerseCallCount == 0)
    }

    @Test("a second skipPrevious tap inside the double-tap window jumps to the previous verse")
    func skipPreviousDoubleTapJumpsToPreviousVerse() {
        let clock = TestClock()
        let service = FakeNarrationService()
        let controller = NarrationController(service: service, now: { clock.now })
        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 4, text: "four"),
            NarrationVerseUtterance(verseNumber: 5, text: "five"),
        ])
        controller._simulateEvent(.started(verseNumber: 5))

        controller.skipPrevious()
        clock.advance(by: 0.5)
        controller.skipPrevious()

        #expect(service.skipBackwardCallCount == 1)
        #expect(service.skipToPreviousVerseCallCount == 1)
    }

    @Test("a second skipPrevious tap after the double-tap window still restarts the current verse")
    func skipPreviousAfterWindowStaysAsRestart() {
        let clock = TestClock()
        let service = FakeNarrationService()
        let controller = NarrationController(service: service, now: { clock.now })
        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 5, text: "five")])
        controller._simulateEvent(.started(verseNumber: 5))

        controller.skipPrevious()
        // Stay clear of the floating-point window boundary.
        clock.advance(by: NarrationController.skipPreviousDoubleTapWindow + 0.1)
        controller.skipPrevious()

        #expect(service.skipBackwardCallCount == 2)
        #expect(service.skipToPreviousVerseCallCount == 0)
    }

    @Test("a third quick tap after a double-tap restarts again, not another jump back")
    func skipPreviousThirdTapRestartsAgain() {
        let clock = TestClock()
        let service = FakeNarrationService()
        let controller = NarrationController(service: service, now: { clock.now })
        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 4, text: "four"),
            NarrationVerseUtterance(verseNumber: 5, text: "five"),
        ])
        controller._simulateEvent(.started(verseNumber: 5))

        controller.skipPrevious()             // tap 1 → restart
        clock.advance(by: 0.2)
        controller.skipPrevious()             // tap 2 (inside window) → previous verse
        clock.advance(by: 0.2)
        controller.skipPrevious()             // tap 3 (inside what would be a chain) → restart again

        #expect(service.skipBackwardCallCount == 2)
        #expect(service.skipToPreviousVerseCallCount == 1)
    }

    @Test(".failed lands the controller in .idle with lastError populated")
    func failedEndsInIdleWithLastError() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "x")])
        controller._simulateEvent(.started(verseNumber: 1))

        controller._simulateEvent(.failed(.audioSessionFailed("boom")))

        #expect(controller.state == .idle)
        #expect(controller.currentVerseNumber == nil)
        #expect(controller.lastError == .audioSessionFailed("boom"))
    }

    @Test("a second start while speaking replaces the session (startCallCount == 2)")
    func secondStartReplacesActiveSession() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "one")])
        controller._simulateEvent(.started(verseNumber: 1))

        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 10, text: "ten"),
            NarrationVerseUtterance(verseNumber: 11, text: "eleven"),
        ])
        #expect(service.startCallCount == 2)

        controller._simulateEvent(.started(verseNumber: 10))
        #expect(controller.currentVerseNumber == 10)
        #expect(controller.state == .speaking)
    }

    @Test("a session replacement cancels the prior streamTask before it can process the buffered .cancelled")
    func secondStartCancelsPriorStreamTaskBeforeIdleOverwrite() async {
        // Starting a replacement buffers cancelled in the old stream. Its consumer must
        // exit before handling that event, or it resets the new session to idle.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "one")])
        controller._simulateEvent(.started(verseNumber: 1))

        // Capture before replacement drops the only handle needed to drain the old consumer.
        let priorTask = controller._currentStreamTask

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 10, text: "ten")])
        controller._simulateEvent(.started(verseNumber: 10))

        // Drain the old consumer to expose any late mutation of the new session.
        await priorTask?.value

        #expect(controller.state == .speaking)
        #expect(controller.currentVerseNumber == 10)
    }

    @Test("setting `rate` propagates to the service via setRate(_:)")
    func rateSetterPropagatesToService() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.rate = 0.8
        #expect(service.setRateCalls == [0.8])
        controller.rate = 1.2
        #expect(service.setRateCalls == [0.8, 1.2])
    }

    @Test("re-assigning `rate` to its current value does NOT trigger setRate")
    func rateSetterIsIdempotent() {
        // SwiftUI Menu writes even the current selection; forwarding it would restart speech mid-verse.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.rate = 1.25
        controller.rate = 1.25  // same value
        #expect(service.setRateCalls == [1.25])
    }

    @Test("setting `voice` propagates to the service via setVoice(_:)")
    func voiceSetterPropagatesToService() throws {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        let voice = AVSpeechSynthesisVoice(language: "en-US")
        controller.voice = voice.map(NarrationVoice.init)
        #expect(service.setVoiceCalls.count == 1)
        #expect(service.setVoiceCalls.first??.identifier == voice?.identifier)

        controller.voice = nil  // back to default
        #expect(service.setVoiceCalls.count == 2)
        // Distinguish a recorded nil voice from an empty call list.
        let lastCall = try #require(service.setVoiceCalls.last)
        #expect(lastCall == nil)
    }

    @Test("re-assigning `voice` to a voice with the same identifier does NOT trigger setVoice")
    func voiceSetterIsIdempotent() {
        // Compare voice identifiers: reselecting the same voice must not restart speech.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        let voice = AVSpeechSynthesisVoice(language: "en-US")
        controller.voice = voice.map(NarrationVoice.init)
        controller.voice = AVSpeechSynthesisVoice(language: "en-US").map(NarrationVoice.init)
        #expect(service.setVoiceCalls.count == 1)
    }
}
