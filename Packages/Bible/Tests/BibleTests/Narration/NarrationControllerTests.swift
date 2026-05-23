import AVFoundation
import Foundation
import Testing
@testable import Bible

/// Tests for ``NarrationController``'s state machine: how it maps the
/// service's `AsyncStream<NarrationEvent>` into the public `state` /
/// `currentVerseNumber` / `lastError` it exposes to the Bible reader and
/// transport sheet. The fake service drives the stream directly, so these
/// assertions don't depend on `AVSpeechSynthesizer`.
///
/// Synchronization model: tests drive the controller's state machine via
/// the controller's `_simulateEvent(_:)` test seam rather than yielding
/// events through the `AsyncStream` and polling for the consumer Task to
/// wake up. The seam calls `handle(_:)` directly on `@MainActor`, so a
/// `#expect` on the following line reads the post-event state without
/// scheduler races — per root AGENTS.md §Testing.2 ("polling loops are
/// race amplifiers, not synchronization primitives").
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
        // Even if a sloppy controller forwarded both stops, only one
        // .cancelled event should ever land back from the service.
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
        // Pad slightly past the window so a flaky float comparison
        // doesn't have us inadvertently inside it.
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
        // Regression guard for the race the production service
        // creates: `service.startSpeaking(...)` internally yields
        // `.cancelled` into the *old* stream before closing it
        // (`AVSpeechSynthesizerNarrationService.teardownActiveSession`),
        // so the prior stream-consumer Task has a buffered terminal
        // event queued. Without the `!Task.isCancelled` guard in the
        // for-await loop, that processing runs *after* the new
        // session is set up and overwrites
        // `state = .speaking` / `currentVerseNumber = 10` with
        // `.idle` / `nil` — the user-visible glitch is the nav-bar
        // speaker flickering back to sparkles on every Narrate re-tap.
        //
        // The fake's `startSpeaking` mirrors the production teardown's
        // yield-`.cancelled`-then-finish sequence, so this test
        // exercises the same race. Without the fix the bottom
        // assertions see `.idle`.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 1, text: "one")])
        // Use the synchronous seam to advance to `.speaking` — we
        // need the controller in a non-idle state before triggering
        // the replacement.
        controller._simulateEvent(.started(verseNumber: 1))

        // Capture the prior streamTask before `start(_:)` replaces it
        // — once replaced, the controller no longer references it and
        // there's no other handle to await.
        let priorTask = controller._currentStreamTask

        controller.start(utterances: [NarrationVerseUtterance(verseNumber: 10, text: "ten")])
        controller._simulateEvent(.started(verseNumber: 10))

        // Deterministically wait for the prior task to exit. With the
        // fix, the for-await guard sees `Task.isCancelled` on the next
        // iteration and bails *before* `handle(.cancelled)`; without
        // it, the task processes the buffered `.cancelled` and
        // mutates state.
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
        // Regression guard: a SwiftUI `Menu` writes the binding back
        // even when the user re-selects the already-current row. The
        // service-level setRate triggers a stopSpeaking + requeue
        // mid-verse, so a no-op write must NOT propagate.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        controller.rate = 1.25
        controller.rate = 1.25  // same value
        #expect(service.setRateCalls == [1.25])
    }

    @Test("setting `voice` propagates to the service via setVoice(_:)")
    func voiceSetterPropagatesToService() {
        // Regression guard: prior to the v1.1 fix, the controller's
        // `voice` was a plain stored property and changes only took
        // effect on the *next* `start(...)` — the picker felt broken.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        let voice = AVSpeechSynthesisVoice(language: "en-US")
        controller.voice = voice
        #expect(service.setVoiceCalls.count == 1)
        #expect(service.setVoiceCalls.first??.identifier == voice?.identifier)

        controller.voice = nil  // back to default
        #expect(service.setVoiceCalls.count == 2)
        #expect(service.setVoiceCalls.last as? AVSpeechSynthesisVoice? == .some(nil))
    }

    @Test("re-assigning `voice` to a voice with the same identifier does NOT trigger setVoice")
    func voiceSetterIsIdempotent() {
        // Regression guard for the same SwiftUI Menu write-back issue
        // as `rateSetterIsIdempotent`. `AVSpeechSynthesisVoice` isn't
        // `Equatable` so the guard compares identifiers; re-creating
        // the same voice via init(language:) and assigning must be a
        // no-op.
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)

        let voice = AVSpeechSynthesisVoice(language: "en-US")
        controller.voice = voice
        // Same identifier (re-fetched from the same locale init).
        controller.voice = AVSpeechSynthesisVoice(language: "en-US")
        #expect(service.setVoiceCalls.count == 1)
    }
}
