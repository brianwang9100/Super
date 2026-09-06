import AVFoundation
import Foundation

/// Abstraction over Bible verse-by-verse text-to-speech playback ("Narrate"
/// in the UI; the term "Voice Over" is avoided to keep this distinct from
/// iOS's VoiceOver screen reader, which the Bible accessibility labels
/// already drive).
///
/// One session at a time. `startSpeaking(_:rate:voice:)` returns a fresh
/// stream that yields `.started` / `.finishedVerse` per utterance and
/// exactly one terminal event (`.completed`, `.cancelled`, or
/// `.failed(NarrationError)`). The controller subscribes once per session
/// and drives its state machine off these events. Cancelling the consuming
/// `Task` tears down the audio session via the stream's `onTermination`.
///
/// Production conformer is ``AVSpeechSynthesizerNarrationService``
/// (wraps `AVSpeechSynthesizer` + `AVAudioSession`); tests inject the
/// in-memory ``FakeNarrationService`` so the controller's state machine
/// runs without the real synth.
public protocol NarrationService: Sendable {
    /// Cheap synchronous check — used at controller construction so the
    /// caller can short-circuit a Narrate action when the synthesizer has
    /// no installed voices for the user's locale.
    func isAvailable() -> Bool

    /// Preferred installed voice for the locale, or `nil` to use the system
    /// default. Discovery may block, so callers perform it off the main actor.
    func bestAvailableVoice(locale: Locale) -> AVSpeechSynthesisVoice?

    /// Begin a new playback session over `utterances` in array order. The
    /// returned stream emits one `.started` + one `.finishedVerse` per
    /// utterance, then exactly one terminal event (`.completed`,
    /// `.cancelled`, or `.failed`).
    func startSpeaking(
        _ utterances: [NarrationVerseUtterance],
        rate: Float,
        voice: AVSpeechSynthesisVoice?
    ) -> AsyncStream<NarrationEvent>

    /// Pause the active session at a word boundary. No-op if no session
    /// is running.
    func pause()

    /// Resume a paused session. No-op when idle or already speaking.
    func resume()

    /// Cancel the active session. Idempotent; safe to call from `.idle`.
    /// The service yields `.cancelled` exactly once per session before
    /// closing the stream.
    func stop()

    /// Skip to the next utterance in the active queue. Calling at the
    /// last utterance ends the session via `.completed`.
    func skipForward()

    /// Restart the currently-speaking utterance from its first word
    /// (typical media-player "back" semantics — *not* "go to previous
    /// verse"). No-op when idle.
    func skipBackward()

    /// Jump to the verse immediately before the one currently speaking.
    /// No-op when already at the first verse in the queue; the
    /// controller pairs this with a short double-tap window over
    /// `skipBackward()` to give the 2000s-music-player rewind feel
    /// (one tap restarts, a quick second tap jumps back).
    func skipToPreviousVerse()

    /// Live-tune playback rate. `AVSpeechUtterance.rate` is baked in at
    /// queue time, so the production impl cancels and requeues remaining
    /// utterances from the current position with the new rate. The
    /// resulting ~80–150 ms gap is acceptable per the design spec.
    func setRate(_ rate: Float)

    /// Live-switch the synthesizer voice. Like `setRate(_:)`, the
    /// `AVSpeechUtterance.voice` is baked in at queue time, so the
    /// production impl cancels and requeues remaining utterances from
    /// the current verse with the new voice so the change is audible
    /// before the next verse boundary.
    func setVoice(_ voice: AVSpeechSynthesisVoice?)
}

/// One verse worth of synthesized speech.
///
/// `preDelay` and `ipaOverrides` are reserved for a v2 pronunciation pass
/// (proper-noun IPA fixes, paragraph-break breath gaps) — both are empty
/// in v1 so adding them later is additive.
public struct NarrationVerseUtterance: Sendable, Equatable {
    public let verseNumber: Int
    public let text: String
    public let preDelay: TimeInterval
    public let ipaOverrides: [Range<String.Index>: String]

    public init(
        verseNumber: Int,
        text: String,
        preDelay: TimeInterval = 0,
        ipaOverrides: [Range<String.Index>: String] = [:]
    ) {
        self.verseNumber = verseNumber
        self.text = text
        self.preDelay = preDelay
        self.ipaOverrides = ipaOverrides
    }
}

/// One frame of synthesizer progress.
public enum NarrationEvent: Sendable, Equatable {
    /// The utterance for `verseNumber` has started speaking — drives the
    /// reader's underline and the auto-scroll proxy.
    case started(verseNumber: Int)
    /// The utterance for `verseNumber` has just finished — no state
    /// transition on its own; the next `.started` or a terminal event
    /// follows.
    case finishedVerse(verseNumber: Int)
    case paused
    case resumed
    /// The last utterance in the queue finished cleanly.
    case completed
    /// The session was stopped by the user, by an interruption, or by a
    /// new `startSpeaking(...)` replacing it. Yielded exactly once per
    /// session before the stream closes.
    case cancelled
    case failed(NarrationError)
}

/// Failure modes the synthesizer can surface. The controller maps each to
/// `.idle` with a `lastError` so the UI can offer to retry.
public enum NarrationError: Error, Sendable, Equatable {
    /// `AVSpeechSynthesisVoice.speechVoices()` returned empty or the
    /// synthesizer refused to speak the supplied text.
    case unavailable
    /// `AVAudioSession.setCategory` or `setActive` threw — the boxed
    /// message comes from the system error and is surfaced verbatim in
    /// `lastError` for diagnostics.
    case audioSessionFailed(String)
    /// A coordinator probe reported voice input is currently active. The
    /// service refuses to acquire the audio session so the mic keeps it.
    case preemptedByVoiceInput
}
