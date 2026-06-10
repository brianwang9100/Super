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
        service.setVoice(voice)
        #expect(fake.stopCount == stopsBeforeVoice + 1)
        // The current verse (1) restarts — not advanced — and carries the
        // new voice so the change is audible from this verse, not the next.
        #expect(fake.spokenTexts == ["one", "one"])
        #expect(fake.lastUtterance?.voice?.identifier == voice.identifier)
    }
}
