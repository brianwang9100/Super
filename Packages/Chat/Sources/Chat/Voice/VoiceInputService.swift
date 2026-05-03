import Foundation

/// Abstraction over on-device speech recognition. Production conformer is
/// ``SpeechRecognizerVoiceInputService`` (SFSpeech = Apple's
/// Speech-recognition framework + AVAudioEngine); tests inject
/// `FakeVoiceInputService` so the controller's state machine runs without
/// touching the microphone or `SFSpeechRecognizer`.
///
/// One session at a time. `startRecognition(locale:)` builds a fresh
/// recognition request per call and emits a stream that yields zero or
/// more `.partial` events followed by exactly one terminal event
/// (`.final` on a clean stop, or a thrown `VoiceInputError`). Cancelling
/// the consuming `Task` stops the audio engine cleanly via the stream's
/// `onTermination` block.
public protocol VoiceInputService: Sendable {
    /// Cheap synchronous check — used at controller init to decide
    /// whether the composer's mic button should boot dimmed. Returns
    /// `true` when an on-device recognition model is installed for the
    /// requested `locale`.
    func isAvailable(locale: Locale) -> Bool

    /// Idempotent permission prompt covering both Speech Recognition and
    /// Microphone. Returns `.granted` only when **both** permissions
    /// land granted; any other combination collapses to `.denied`.
    /// Calling a second time after a denial does not re-prompt — iOS
    /// returns the cached status.
    func requestPermissions() async -> VoiceInputPermissionStatus

    /// Start a fresh recognition session. The returned stream emits
    /// `.partial(String)` repeatedly as the recognizer refines its
    /// hypothesis, then exactly one terminal event (`.final` on stop or
    /// throws on failure).
    func startRecognition(locale: Locale) -> AsyncThrowingStream<VoiceInputEvent, Error>
}

/// Outcome of a permission prompt. `.granted` only when both Speech
/// Recognition and Microphone are granted; the controller treats every
/// other case as `.denied` for UI purposes.
public enum VoiceInputPermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case restricted
}

/// One frame of recognized text. `.partial` repeats during the session;
/// `.final` arrives exactly once at the end of a clean stop and carries
/// the committed transcript.
public enum VoiceInputEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
}

/// Failures the recognition stream can throw. `silenceTimeout` is treated
/// as a normal stop by the controller — it commits whatever final text
/// the most recent `.partial` event carried — every other case maps to
/// the `.failed(reason)` controller state and surfaces in the error
/// banner.
public enum VoiceInputError: Error, Sendable, Equatable {
    case permissionDenied
    case unavailable
    case recognizerFailed(String)
    case audioEngineFailed(String)
    case silenceTimeout
}
