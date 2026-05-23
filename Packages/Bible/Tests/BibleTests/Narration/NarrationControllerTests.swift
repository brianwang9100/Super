import AVFoundation
import Foundation
import Testing
@testable import Bible

/// Tests for ``NarrationController``'s state machine: how it maps the
/// service's `AsyncStream<NarrationEvent>` into the public `state` /
/// `currentVerseNumber` / `lastError` it exposes to the Bible reader and
/// transport sheet. The fake service drives the stream directly, so these
/// assertions don't depend on `AVSpeechSynthesizer`.
@Suite("NarrationController")
@MainActor
struct NarrationControllerTests {
    @Test("a fresh controller is idle with no current verse")
    func freshControllerIsIdle() {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        #expect(controller.state == .idle)
        #expect(controller.currentVerseNumber == nil)
        #expect(controller.lastError == nil)
    }

    @Test("starting a session forwards utterances and lands in .speaking on the first .started event")
    func startForwardsUtterancesAndTransitionsOnStarted() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let queue = [
            NarrationVerseUtterance(verseNumber: 1, text: "alpha"),
            NarrationVerseUtterance(verseNumber: 2, text: "beta"),
        ]

        controller.start(utterances: queue)
        #expect(service.startCallCount == 1)
        #expect(service.lastStartArgs?.utterances == queue)

        service.emit(.started(verseNumber: 1))
        await yieldUntil { controller.state == .speaking }
        #expect(controller.currentVerseNumber == 1)
    }

    @Test("walking through .started + .finishedVerse for every utterance ends at .completed → idle")
    func wholeQueueWalksToCompletedIdle() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let recorder = CompletionRecorder()
        controller.onCompletion = { recorder.record() }

        controller.start(utterances: (1...3).map {
            NarrationVerseUtterance(verseNumber: $0, text: "verse \($0)")
        })
        for verse in 1...3 {
            service.emit(.started(verseNumber: verse))
            await yieldUntil { controller.currentVerseNumber == verse }
            service.emit(.finishedVerse(verseNumber: verse))
        }
        service.finish(with: .completed)
        await yieldUntil { controller.state == .idle }

        #expect(controller.state == .idle)
        #expect(controller.currentVerseNumber == nil)
        #expect(recorder.firedCount == 1)
    }

    @Test("pause + resume preserves currentVerseNumber and reflects the .paused / .resumed events")
    func pauseResumePreservesCurrentVerse() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 4, text: "four"),
        ])
        service.emit(.started(verseNumber: 4))
        await yieldUntil { controller.state == .speaking }

        controller.pause()
        #expect(service.pauseCallCount == 1)
        service.emit(.paused)
        await yieldUntil { controller.state == .paused }
        #expect(controller.currentVerseNumber == 4)

        controller.resume()
        #expect(service.resumeCallCount == 1)
        service.emit(.resumed)
        await yieldUntil { controller.state == .speaking }
        #expect(controller.currentVerseNumber == 4)
    }

    @Test("stop() is idempotent — calling twice yields .idle once and only one .cancelled is needed")
    func stopIsIdempotent() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let recorder = CompletionRecorder()
        controller.onCompletion = { recorder.record() }

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "x")])
        service.emit(.started(verseNumber: 1))
        await yieldUntil { controller.state == .speaking }

        controller.stop()
        controller.stop()
        // Even if a sloppy controller forwarded both stops, only one
        // .cancelled event should ever land back from the service.
        service.finish(with: .cancelled)
        await yieldUntil { controller.state == .idle }

        #expect(controller.state == .idle)
        #expect(controller.currentVerseNumber == nil)
        #expect(recorder.firedCount == 1)
    }

    @Test("skipNext forwards to the service; the next .started event updates currentVerseNumber")
    func skipNextForwardsAndStateFollowsEvents() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 1, text: "one"),
            NarrationVerseUtterance(verseNumber: 2, text: "two"),
        ])
        service.emit(.started(verseNumber: 1))
        await yieldUntil { controller.currentVerseNumber == 1 }

        controller.skipNext()
        #expect(service.skipForwardCallCount == 1)
        service.emit(.finishedVerse(verseNumber: 1))
        service.emit(.started(verseNumber: 2))
        await yieldUntil { controller.currentVerseNumber == 2 }
    }

    @Test("skipNext on the last utterance completes the session through .completed")
    func skipNextAtLastUtteranceCompletes() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        let recorder = CompletionRecorder()
        controller.onCompletion = { recorder.record() }

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 9, text: "last")])
        service.emit(.started(verseNumber: 9))
        await yieldUntil { controller.currentVerseNumber == 9 }

        controller.skipNext()
        service.finish(with: .completed)
        await yieldUntil { controller.state == .idle }

        #expect(controller.state == .idle)
        #expect(recorder.firedCount == 1)
    }

    @Test("a single skipPrevious tap restarts the current verse")
    func skipPreviousSingleTapRestartsCurrentVerse() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 2, text: "two")])
        service.emit(.started(verseNumber: 2))
        await yieldUntil { controller.currentVerseNumber == 2 }

        controller.skipPrevious()
        #expect(service.skipBackwardCallCount == 1)
        #expect(service.skipToPreviousVerseCallCount == 0)
    }

    @Test("a second skipPrevious tap inside the double-tap window jumps to the previous verse")
    func skipPreviousDoubleTapJumpsToPreviousVerse() async {
        let clock = TestClock()
        let service = FakeNarrationService()
        let controller = NarrationController(service: service, now: { clock.now })
        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 4, text: "four"),
            NarrationVerseUtterance(verseNumber: 5, text: "five"),
        ])
        service.emit(.started(verseNumber: 5))
        await yieldUntil { controller.currentVerseNumber == 5 }

        controller.skipPrevious()
        clock.advance(by: 0.5)
        controller.skipPrevious()

        #expect(service.skipBackwardCallCount == 1)
        #expect(service.skipToPreviousVerseCallCount == 1)
    }

    @Test("a second skipPrevious tap after the double-tap window still restarts the current verse")
    func skipPreviousAfterWindowStaysAsRestart() async {
        let clock = TestClock()
        let service = FakeNarrationService()
        let controller = NarrationController(service: service, now: { clock.now })
        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 5, text: "five")])
        service.emit(.started(verseNumber: 5))
        await yieldUntil { controller.currentVerseNumber == 5 }

        controller.skipPrevious()
        // Pad slightly past the window so a flaky float comparison
        // doesn't have us inadvertently inside it.
        clock.advance(by: NarrationController.skipPreviousDoubleTapWindow + 0.1)
        controller.skipPrevious()

        #expect(service.skipBackwardCallCount == 2)
        #expect(service.skipToPreviousVerseCallCount == 0)
    }

    @Test("a third quick tap after a double-tap restarts again, not another jump back")
    func skipPreviousThirdTapRestartsAgain() async {
        let clock = TestClock()
        let service = FakeNarrationService()
        let controller = NarrationController(service: service, now: { clock.now })
        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 4, text: "four"),
            NarrationVerseUtterance(verseNumber: 5, text: "five"),
        ])
        service.emit(.started(verseNumber: 5))
        await yieldUntil { controller.currentVerseNumber == 5 }

        controller.skipPrevious()             // tap 1 → restart
        clock.advance(by: 0.2)
        controller.skipPrevious()             // tap 2 (inside window) → previous verse
        clock.advance(by: 0.2)
        controller.skipPrevious()             // tap 3 (inside what would be a chain) → restart again

        #expect(service.skipBackwardCallCount == 2)
        #expect(service.skipToPreviousVerseCallCount == 1)
    }

    @Test(".failed lands the controller in .idle with lastError populated")
    func failedEndsInIdleWithLastError() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "x")])
        service.emit(.started(verseNumber: 1))
        await yieldUntil { controller.state == .speaking }

        service.finish(with: .failed(.audioSessionFailed("boom")))
        await yieldUntil { controller.state == .idle }

        #expect(controller.state == .idle)
        #expect(controller.currentVerseNumber == nil)
        #expect(controller.lastError == .audioSessionFailed("boom"))
    }

    @Test("a second start while speaking replaces the session (startCallCount == 2)")
    func secondStartReplacesActiveSession() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "one")])
        service.emit(.started(verseNumber: 1))
        await yieldUntil { controller.currentVerseNumber == 1 }

        controller.start(utterances: [
            NarrationVerseUtterance(verseNumber: 10, text: "ten"),
            NarrationVerseUtterance(verseNumber: 11, text: "eleven"),
        ])
        #expect(service.startCallCount == 2)

        service.emit(.started(verseNumber: 10))
        await yieldUntil { controller.currentVerseNumber == 10 }
        #expect(controller.state == .speaking)
    }

    @Test("setting `rate` propagates to the service via setRate(_:)")
    func rateSetterPropagatesToService() async {
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.rate = 0.8
        await yieldUntil { service.setRateCalls == [0.8] }
        controller.rate = 1.2
        await yieldUntil { service.setRateCalls == [0.8, 1.2] }
    }

    @Test("re-assigning `rate` to its current value does NOT trigger setRate")
    func rateSetterIsIdempotent() async {
        // Regression guard: a SwiftUI `Menu` writes the binding back
        // even when the user re-selects the already-current row. The
        // service-level setRate triggers a stopSpeaking + requeue
        // mid-verse, so a no-op write must NOT propagate.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.rate = 1.25
        await yieldUntil { service.setRateCalls == [1.25] }
        controller.rate = 1.25  // same value
        // Yield a few times so any spurious dispatch would land.
        for _ in 0..<5 { await Task.yield() }
        #expect(service.setRateCalls == [1.25])
    }

    @Test("setting `voice` propagates to the service via setVoice(_:)")
    func voiceSetterPropagatesToService() async {
        // Regression guard: prior to the v1.1 fix, the controller's
        // `voice` was a plain stored property and changes only took
        // effect on the *next* `start(...)` — the picker felt broken.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        let voice = AVSpeechSynthesisVoice(language: "en-US")
        controller.voice = voice
        await yieldUntil { service.setVoiceCalls.count == 1 }
        #expect(service.setVoiceCalls.first??.identifier == voice?.identifier)

        controller.voice = nil  // back to default
        await yieldUntil { service.setVoiceCalls.count == 2 }
        #expect(service.setVoiceCalls.last as? AVSpeechSynthesisVoice? == .some(nil))
    }

    @Test("re-assigning `voice` to a voice with the same identifier does NOT trigger setVoice")
    func voiceSetterIsIdempotent() async {
        // Regression guard for the same SwiftUI Menu write-back issue
        // as `rateSetterIsIdempotent`. `AVSpeechSynthesisVoice` isn't
        // `Equatable` so the guard compares identifiers; re-creating
        // the same voice via init(language:) and assigning must be a
        // no-op.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        let voice = AVSpeechSynthesisVoice(language: "en-US")
        controller.voice = voice
        await yieldUntil { service.setVoiceCalls.count == 1 }
        // Same identifier (re-fetched from the same locale init).
        controller.voice = AVSpeechSynthesisVoice(language: "en-US")
        for _ in 0..<5 { await Task.yield() }
        #expect(service.setVoiceCalls.count == 1)
    }

    /// Spin the @MainActor task pool until `condition()` is true or the
    /// poll cap trips. Mirrors `VoiceInputControllerTests.yieldUntil`.
    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
        }
    }
}
