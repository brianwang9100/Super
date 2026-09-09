import Core
import Foundation

/// One session at a time. Cancelling stream consumption tears down its audio session.
public protocol NarrationService: Sendable {
    /// Cheap synchronous availability check; do blocking voice discovery separately.
    @MainActor func isAvailable() -> Bool

    /// Preferred installed voice for the locale, or `nil` to use the system
    /// default. Discovery may block, so callers perform it off the main actor.
    func bestAvailableVoice(locale: Locale) -> NarrationVoice?

    /// Plays in array order, emitting started/finishedVerse per played utterance and
    /// exactly one terminal event: completed, cancelled, or failed.
    @MainActor func startSpeaking(
        _ utterances: [NarrationVerseUtterance],
        rate: Float,
        voice: NarrationVoice?,
        startingAt: Int
    ) -> AsyncStream<NarrationEvent>

    /// Pause the active session at a word boundary. No-op if no session
    /// is running.
    @MainActor func pause()

    /// Resume a paused session. No-op when idle or already speaking.
    @MainActor func resume()

    /// Idempotent; emits cancelled once for the active session before closing its stream.
    @MainActor func stop()

    /// At the last utterance, skipping forward completes the session.
    @MainActor func skipForward()

    /// Restarts the current utterance from its beginning; no-op while idle.
    @MainActor func skipBackward()

    /// No-op at the first verse. The controller invokes this on a double back tap.
    @MainActor func skipToPreviousVerse()

    /// Live rate changes may restart the current utterance because AVSpeech bakes rate in at enqueue.
    @MainActor func setRate(_ rate: Float)

    /// Live voice changes restart the current verse so the change is audible immediately.
    @MainActor func setVoice(_ voice: NarrationVoice?)
}

/// preDelay is in seconds. ipaOverrides is reserved for pronunciation support.
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

public enum NarrationEvent: Sendable, Equatable {
    /// Waiting for audio for this verse; cached handoffs do not emit this event.
    case preparing(verseNumber: Int)
    case started(verseNumber: Int)
    /// Finishing a verse alone does not change controller state; another start or terminal event follows.
    case finishedVerse(verseNumber: Int)
    case paused
    /// Audible playback continues after a pause or buffering within a segmented verse.
    case resumed
    case completed
    /// Terminal event for explicit stop or replacement by a new session.
    case cancelled
    /// The attempted verse supports recovery when failure precedes buffering or playback.
    case failed(NarrationError, verseNumber: Int? = nil)
}

public enum NarrationError: Error, Sendable, Equatable {
    /// No installed voice or the synthesizer refused the text.
    case unavailable
    case speech(SpeechGenerationError)
    /// Carries the system audio-session error for diagnostics.
    case audioSessionFailed(String)
    case preemptedByVoiceInput
}

public extension NarrationError {
    var message: String {
        switch self {
        case .unavailable: "No narration voice is available."
        case .audioSessionFailed: "Audio playback could not start. Please try again."
        case .preemptedByVoiceInput: "Finish dictating before starting narration."
        case .speech(let error): error.message
        }
    }
}

public extension NarrationService {
    @MainActor func startSpeaking(_ utterances: [NarrationVerseUtterance], rate: Float, voice: NarrationVoice?) -> AsyncStream<NarrationEvent> {
        startSpeaking(utterances, rate: rate, voice: voice, startingAt: 0)
    }
}
