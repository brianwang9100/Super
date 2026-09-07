import AVFoundation
import Foundation
import Testing
@testable import Bible

/// Tests for ``AVSpeechSynthesizerNarrationService``'s queueing through the
/// ``SpeechSynthesizing`` seam: the service speaks **one verse at a time**,
/// queuing the next only when the current one's `didFinish` lands, so the
/// app's `currentIndex` — not the synthesizer's opaque internal queue —
/// drives playback order.
///
/// This is the regression guard for the narration misorder: queuing a whole
/// chapter at once let the synthesizer hand back utterances out of order or
/// a verse short on devices whose Enhanced/Premium voice streams in
/// mid-queue (heard as "started on verse 6", then "jumped back to verse 5").
/// Against the old batch-queue service these `spokenTexts` assertions fail —
/// `startSpeaking` queued every verse immediately, so the count was 3, not 1.
///
/// The fake records `speak(_:)` calls; the test fires the synthesizer
/// delegate callbacks directly (the production code ignores the
/// `synthesizer` argument, so a throwaway `AVSpeechSynthesizer` satisfies
/// the signature). No audio hardware, no real-time waits.
@Suite("AVSpeechSynthesizerNarrationService queueing")
struct AVSpeechSynthesizerNarrationServiceTests {
    private func utterance(_ number: Int, _ text: String) -> NarrationVerseUtterance {
        NarrationVerseUtterance(verseNumber: number, text: text)
    }

    /// A throwaway synthesizer to satisfy the delegate signature; the
    /// service never reads it.
    private let unusedSynth = AVSpeechSynthesizer()

    @Test("refused Resume after an acknowledged pause finishes with a recoverable failure")
    func refusedResumeAfterPauseFails() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(4, "four")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.pause()
        service.speechSynthesizer(unusedSynth, didPause: current)
        let stopsBeforeResume = fake.stopCount
        fake.continueResult = false
        service.resume()

        #expect(fake.stopCount == stopsBeforeResume + 1)
        service.resume()
        #expect(fake.continueCount == 1)
        service.speechSynthesizer(unusedSynth, didContinue: current)
        service.speechSynthesizer(unusedSynth, didCancel: current)
        // Bound collection against the unfixed service, which leaves the stream open.
        service.stop()
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 4), .paused, .failed(.unavailable, verseNumber: 4)])

        let retry = service.startSpeaking([utterance(4, "four")], rate: 1, voice: nil)
        let retried = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: retried)
        service.speechSynthesizer(unusedSynth, didFinish: retried)
        let retryEvents = await retry.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(retryEvents == [.started(verseNumber: 4), .finishedVerse(verseNumber: 4), .completed])
    }

    @Test("requeues discard the replaced utterance's actual paused state", arguments: [false, true])
    func requeueDoesNotInheritAcknowledgedPause(changesVoice: Bool) async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let old = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: old)
        service.pause()
        service.speechSynthesizer(unusedSynth, didPause: old)
        if changesVoice { service.setVoice(nil) } else { service.setRate(1.5) }
        service.speechSynthesizer(unusedSynth, didPause: old)
        service.speechSynthesizer(unusedSynth, didContinue: old)
        fake.continueResult = false
        let stopsBeforeResume = fake.stopCount
        service.resume()
        #expect(fake.stopCount == stopsBeforeResume)

        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.speechSynthesizer(unusedSynth, didFinish: current)
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [
            .started(verseNumber: 1), .paused, .started(verseNumber: 1), .finishedVerse(verseNumber: 1), .completed,
        ])
    }

    @Test("refused corrective continuation after a late pause also fails safely")
    func refusedContinuationAfterLatePauseFails() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(3, "three")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.pause()
        fake.continueResult = false
        service.resume()
        service.speechSynthesizer(unusedSynth, didPause: current)
        service.stop()

        #expect(fake.continueCount == 2)
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 3), .failed(.unavailable, verseNumber: 3)])
    }

    @Test("a synchronous resumed acknowledgement supersedes a refused continuation result")
    func continuedAcknowledgementSupersedesRefusal() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.pause()
        service.speechSynthesizer(unusedSynth, didPause: current)
        fake.continueResult = false
        fake.onContinueAttempt = { [weak service] in
            service?.speechSynthesizer(unusedSynth, didContinue: current)
        }
        let stopsBeforeResume = fake.stopCount
        service.resume()
        #expect(fake.stopCount == stopsBeforeResume)
        service.speechSynthesizer(unusedSynth, didFinish: current)

        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .paused, .resumed, .finishedVerse(verseNumber: 1), .completed])
    }

    @Test("a newer Pause request supersedes a refused continuation result")
    func newerPauseSupersedesRefusal() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.pause()
        service.speechSynthesizer(unusedSynth, didPause: current)
        fake.continueResult = false
        fake.onContinueAttempt = { [weak service] in service?.pause() }
        let stopsBeforeResume = fake.stopCount
        service.resume()
        #expect(fake.stopCount == stopsBeforeResume)
        service.stop()

        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .paused, .cancelled])
    }

    @Test("a stopped or replaced session ignores an old refused continuation", arguments: [false, true])
    func replacementSupersedesRefusal(startsReplacement: Bool) async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.pause()
        service.speechSynthesizer(unusedSynth, didPause: current)
        fake.continueResult = false
        var replacement: AsyncStream<NarrationEvent>?
        fake.onContinueAttempt = { [weak service] in
            service?.stop()
            if startsReplacement {
                replacement = service?.startSpeaking([utterance(2, "two")], rate: 1, voice: nil)
            }
        }
        let stopsBeforeResume = fake.stopCount
        service.resume()
        #expect(fake.stopCount == stopsBeforeResume + (startsReplacement ? 2 : 1))
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .paused, .cancelled])

        if let replacement {
            let replaced = try #require(fake.lastUtterance)
            service.speechSynthesizer(unusedSynth, didStart: replaced)
            service.speechSynthesizer(unusedSynth, didFinish: replaced)
            let replacementEvents = await replacement.reduce(into: [NarrationEvent]()) { $0.append($1) }
            #expect(replacementEvents == [.started(verseNumber: 2), .finishedVerse(verseNumber: 2), .completed])
        }
    }

    @Test("a refused preparing pause is retried when the same utterance starts")
    func preparingPauseIsRetriedOnStart() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        fake.pauseResult = false
        service.pause()
        #expect(fake.pauseBoundaries == [.word])

        fake.pauseResult = true
        fake.onPause = { [weak service] in
            service?.speechSynthesizer(unusedSynth, didPause: current)
        }
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.stop()

        #expect(fake.pauseBoundaries == [.word, .immediate])
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .paused, .cancelled])
    }

    @Test("a second refused pause never reports a pause acknowledgement")
    func refusedStartPauseDoesNotClaimPaused() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        fake.pauseResult = false
        service.pause()
        service.speechSynthesizer(unusedSynth, didStart: try #require(fake.lastUtterance))
        service.stop()

        #expect(fake.pauseBoundaries == [.word, .immediate])
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .cancelled])
    }

    @Test("ordinary playback pauses at a word boundary and resumes on acknowledgement")
    func activePauseAndResumeKeepEventOrder() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        fake.onPause = { [weak service] in service?.speechSynthesizer(unusedSynth, didPause: current) }
        fake.onContinue = { [weak service] in service?.speechSynthesizer(unusedSynth, didContinue: current) }
        service.pause()
        service.resume()
        service.stop()

        #expect(fake.pauseBoundaries == [.word])
        #expect(fake.continueCount == 1)
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .paused, .resumed, .cancelled])
    }

    @Test("Resume withdraws a preparing pause before the utterance starts")
    func resumeWithdrawsPreparingPause() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        fake.pauseResult = false
        fake.continueResult = false
        service.pause()
        service.resume()
        service.speechSynthesizer(unusedSynth, didStart: try #require(fake.lastUtterance))
        service.stop()

        #expect(fake.pauseBoundaries == [.word])
        #expect(fake.continueCount == 1)
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .cancelled])
    }

    @Test("a replacement session ignores the old utterance's pending pause and callbacks")
    func replacementDoesNotInheritPreparingPause() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let oldStream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let old = try #require(fake.lastUtterance)
        fake.pauseResult = false
        service.pause()
        let stream = service.startSpeaking([utterance(2, "two")], rate: 1, voice: nil)

        service.speechSynthesizer(unusedSynth, didStart: old)
        service.speechSynthesizer(unusedSynth, didPause: old)
        service.speechSynthesizer(unusedSynth, didContinue: old)
        service.speechSynthesizer(unusedSynth, didFinish: old)
        service.speechSynthesizer(unusedSynth, didCancel: old)
        service.speechSynthesizer(unusedSynth, didStart: try #require(fake.lastUtterance))
        service.stop()

        #expect(fake.pauseBoundaries == [.word])
        #expect(fake.continueCount == 0)
        #expect(fake.spokenTexts == ["one", "two"])
        let oldEvents = await oldStream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(oldEvents == [.cancelled])
        #expect(events == [.started(verseNumber: 2), .cancelled])
    }

    @Test("rate and voice requeues retain pending pause without accepting stale callbacks", arguments: [false, true])
    func requeueRetainsPreparingPause(changesVoice: Bool) async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one"), utterance(2, "two")], rate: 1, voice: nil)
        let old = try #require(fake.lastUtterance)
        fake.pauseResult = false
        service.pause()
        if changesVoice {
            let voice = try #require(AVSpeechSynthesisVoice(language: "en-US"))
            service.setVoice(NarrationVoice(voice))
            #expect(fake.lastUtterance?.voice?.identifier == voice.identifier)
        } else {
            service.setRate(1.5)
            #expect(fake.lastUtterance?.rate == AVSpeechSynthesizerNarrationService.absoluteRate(forMultiple: 1.5))
        }
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: old)
        service.speechSynthesizer(unusedSynth, didPause: old)
        service.speechSynthesizer(unusedSynth, didContinue: old)
        service.speechSynthesizer(unusedSynth, didFinish: old)
        service.speechSynthesizer(unusedSynth, didCancel: old)
        #expect(fake.pauseBoundaries == [.word])
        #expect(fake.continueCount == 0)

        fake.pauseResult = true
        fake.onPause = { [weak service] in service?.speechSynthesizer(unusedSynth, didPause: current) }
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.stop()

        #expect(fake.spokenTexts == ["one", "one"])
        #expect(fake.pauseBoundaries == [.word, .immediate])
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .paused, .cancelled])
    }

    @Test("skip requeues preserve pending pause for the destination verse", arguments: [false, true])
    func skipRetainsPreparingPause(forward: Bool) async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking(
            [utterance(1, "one"), utterance(2, "two"), utterance(3, "three")],
            rate: 1, voice: nil, startingAt: 1
        )
        fake.pauseResult = false
        service.pause()
        if forward { service.skipForward() } else { service.skipToPreviousVerse() }
        let current = try #require(fake.lastUtterance)
        fake.pauseResult = true
        fake.onPause = { [weak service] in service?.speechSynthesizer(unusedSynth, didPause: current) }
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.stop()

        #expect(fake.spokenTexts == ["two", forward ? "three" : "one"])
        #expect(fake.pauseBoundaries == [.word, .immediate])
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: forward ? 3 : 1), .paused, .cancelled])
    }

    @Test("a late pause acknowledgement follows the newer Resume request")
    func latePauseAcknowledgementContinuesCurrentUtterance() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.pause()
        fake.continueResult = false
        service.resume()
        fake.continueResult = true
        fake.onContinue = { [weak service] in service?.speechSynthesizer(unusedSynth, didContinue: current) }
        service.speechSynthesizer(unusedSynth, didPause: current)
        service.stop()

        #expect(fake.continueCount == 2)
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .resumed, .cancelled])
    }

    @Test("a late continuation acknowledgement follows the newer Pause request")
    func lateContinueAcknowledgementPausesCurrentUtterance() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        let stream = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let current = try #require(fake.lastUtterance)
        service.speechSynthesizer(unusedSynth, didStart: current)
        service.pause()
        service.speechSynthesizer(unusedSynth, didPause: current)
        service.resume()
        service.pause()
        fake.onPause = { [weak service] in service?.speechSynthesizer(unusedSynth, didPause: current) }
        service.speechSynthesizer(unusedSynth, didContinue: current)
        service.stop()

        #expect(fake.pauseBoundaries == [.word, .word, .immediate])
        let events = await stream.reduce(into: [NarrationEvent]()) { $0.append($1) }
        #expect(events == [.started(verseNumber: 1), .paused, .paused, .cancelled])
    }

    @Test("a delayed interruption cannot pause a replacement session")
    @MainActor
    func delayedInterruptionIgnoresReplacementSession() async throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)
        _ = service.startSpeaking([utterance(1, "one")], rate: 1, voice: nil)
        let interruption = service.pauseForAudioInterruption()
        let stream = service.startSpeaking([utterance(2, "two")], rate: 1, voice: nil)
        await interruption?.value
        service.speechSynthesizer(unusedSynth, didStart: try #require(fake.lastUtterance))
        service.stop()

        #expect(fake.pauseBoundaries.isEmpty)
        var events: [NarrationEvent] = []
        for await event in stream { events.append(event) }
        #expect(events == [.started(verseNumber: 2), .cancelled])
    }

    @Test("startSpeaking queues only the first verse; each finish queues exactly the next")
    func queuesOneVerseAtATime() {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)

        _ = service.startSpeaking(
            [utterance(1, "one"), utterance(2, "two"), utterance(3, "three")],
            rate: 1, voice: nil
        )
        // The whole chapter is *not* queued — only verse 1.
        #expect(fake.spokenTexts == ["one"])

        service.speechSynthesizer(unusedSynth, didFinish: fake.lastUtterance!)
        #expect(fake.spokenTexts == ["one", "two"])

        service.speechSynthesizer(unusedSynth, didFinish: fake.lastUtterance!)
        #expect(fake.spokenTexts == ["one", "two", "three"])

        // The last verse finished — nothing further is queued.
        service.speechSynthesizer(unusedSynth, didFinish: fake.lastUtterance!)
        #expect(fake.spokenTexts == ["one", "two", "three"])
    }

    @Test("the event stream reports started → finishedVerse per verse, then completed")
    func emitsOrderedEventsThenCompletes() async {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)

        let stream = service.startSpeaking(
            [utterance(1, "one"), utterance(2, "two")], rate: 1, voice: nil
        )
        // Collect every event; the stream finishes when `.completed` lands.
        let collector = Task { await stream.reduce(into: [NarrationEvent]()) { $0.append($1) } }

        // Play verse 1, then verse 2 (queued by verse 1's finish).
        service.speechSynthesizer(unusedSynth, didStart: fake.lastUtterance!)
        service.speechSynthesizer(unusedSynth, didFinish: fake.lastUtterance!)
        service.speechSynthesizer(unusedSynth, didStart: fake.lastUtterance!)
        service.speechSynthesizer(unusedSynth, didFinish: fake.lastUtterance!)

        let events = await collector.value
        #expect(events == [
            .started(verseNumber: 1),
            .finishedVerse(verseNumber: 1),
            .started(verseNumber: 2),
            .finishedVerse(verseNumber: 2),
            .completed,
        ])
    }

    @Test("skipForward stops the current verse and queues the next one only")
    func skipForwardRequeuesSingleVerse() {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)

        _ = service.startSpeaking(
            [utterance(1, "one"), utterance(2, "two"), utterance(3, "three")],
            rate: 1, voice: nil
        )
        service.speechSynthesizer(unusedSynth, didStart: fake.lastUtterance!)
        #expect(fake.spokenTexts == ["one"])

        // `startSpeaking` stops once up front to clear any prior session;
        // measure the additional stop the skip's requeue triggers.
        let stopsBeforeSkip = fake.stopCount
        service.skipForward()
        #expect(fake.stopCount == stopsBeforeSkip + 1)
        // Verse 2 is queued — verse 3 is not (still one at a time).
        #expect(fake.spokenTexts == ["one", "two"])
    }

    @Test("changing rate restarts the current verse only")
    func setRateRequeuesCurrentVerse() {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)

        _ = service.startSpeaking(
            [utterance(1, "one"), utterance(2, "two")], rate: 1, voice: nil
        )
        service.speechSynthesizer(unusedSynth, didStart: fake.lastUtterance!)

        let stopsBeforeRate = fake.stopCount
        service.setRate(1.5)
        #expect(fake.stopCount == stopsBeforeRate + 1)
        // The current verse (1) is re-spoken — not advanced to verse 2.
        #expect(fake.spokenTexts == ["one", "one"])
    }

    @Test("a late didFinish for a verse cancelled by skip does not advance the session")
    func staleFinishAfterSkipIsIgnored() {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)

        _ = service.startSpeaking(
            [utterance(1, "one"), utterance(2, "two"), utterance(3, "three")],
            rate: 1, voice: nil
        )
        service.speechSynthesizer(unusedSynth, didStart: fake.lastUtterance!)
        let cancelledVerseOne = fake.lastUtterance!

        // Skip to verse 2; verse 1's entry is wiped under the new session
        // version before its synth is stopped.
        service.skipForward()
        #expect(fake.spokenTexts == ["one", "two"])

        // Verse 1's delayed `didFinish` arrives — it must be dropped, not
        // mistaken for "verse 2 finished, advance to verse 3".
        service.speechSynthesizer(unusedSynth, didFinish: cancelledVerseOne)
        #expect(fake.spokenTexts == ["one", "two"])
    }

    @Test("skipBackward restarts the current verse without advancing")
    func skipBackwardRestartsCurrentVerse() {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)

        _ = service.startSpeaking(
            [utterance(1, "one"), utterance(2, "two")], rate: 1, voice: nil
        )
        service.speechSynthesizer(unusedSynth, didStart: fake.lastUtterance!)

        let stopsBeforeBack = fake.stopCount
        service.skipBackward()
        #expect(fake.stopCount == stopsBeforeBack + 1)
        // The current verse (1) is re-spoken — not advanced to verse 2.
        #expect(fake.spokenTexts == ["one", "one"])
    }

    @Test("changing voice restarts the current verse under the new voice")
    func setVoiceRequeuesCurrentVerseWithNewVoice() throws {
        let fake = FakeSpeechSynthesizer()
        let service = AVSpeechSynthesizerNarrationService(coordinator: nil, synthesizer: fake)

        _ = service.startSpeaking(
            [utterance(1, "one"), utterance(2, "two")], rate: 1, voice: nil
        )
        service.speechSynthesizer(unusedSynth, didStart: fake.lastUtterance!)

        let voice = try #require(AVSpeechSynthesisVoice(language: "en-US"))
        let stopsBeforeVoice = fake.stopCount
        service.setVoice(NarrationVoice(voice))
        #expect(fake.stopCount == stopsBeforeVoice + 1)
        // The current verse (1) restarts — not advanced — and carries the
        // new voice so the change is audible from this verse, not the next.
        #expect(fake.spokenTexts == ["one", "one"])
        #expect(fake.lastUtterance?.voice?.identifier == voice.identifier)
    }
}
