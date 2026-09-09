import Foundation

/// Injectable on-device recognition source. Each stream carries current-utterance
/// hypotheses and completed phrases, never the accumulated text of prior utterances.
/// Only one session may run at a time. Cancellation also tears down capture.
public protocol VoiceInputService: Sendable {
    /// Whether an on-device recognition model is available for this locale.
    func isAvailable(locale: Locale) -> Bool

    /// Requests both speech and microphone permissions, respecting cached denials.
    func requestPermissions() async -> VoiceInputPermissionStatus

    /// Emits partials and nonterminal utterances until a final event or error.
    func startRecognition(locale: Locale) -> AsyncThrowingStream<VoiceInputEvent, Error>

    /// Releases capture synchronously and finishes the stream, preserving queued events.
    /// No further events may be emitted after this returns.
    func stopRecognition()
}

/// Combined speech-recognition and microphone authorization result.
public enum VoiceInputPermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case restricted
}

/// A current-utterance hypothesis, completed phrase at a pause, or terminal phrase.
/// Each utterance is delivered once; identical successive phrases remain distinct.
public enum VoiceInputEvent: Sendable, Equatable {
    case partial(String)
    case utterance(String)
    case final(String)
}

/// Recognition failures. All terminal paths preserve the pending speech; silence
/// timeout returns to idle while other failures surface the corresponding UI state.
public enum VoiceInputError: Error, Sendable, Equatable {
    case permissionDenied
    case unavailable
    case recognizerFailed(String)
    case audioEngineFailed(String)
    case silenceTimeout
}
