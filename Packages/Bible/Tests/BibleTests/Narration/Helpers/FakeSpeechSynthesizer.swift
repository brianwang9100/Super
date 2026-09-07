import AVFoundation
@testable import Bible

/// Strict test double for the ``SpeechSynthesizing`` seam. Records the
/// `AVSpeechUtterance`s handed to `speak(_:)` (and counts `stopSpeaking`)
/// so a test can assert the production rule that **only one utterance is
/// ever queued at a time**, then drive the synthesizer delegate
/// callbacks by hand — no real synthesizer, no audio hardware, no
/// real-time waiting.
final class FakeSpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?

    // The tests drive the synthesizer synchronously on one thread (they
    // fire the delegate callbacks by hand), so these recorders are never
    // raced — `nonisolated(unsafe)` states that plainly rather than
    // claiming a false `@unchecked Sendable` conformance.
    /// Every utterance passed to `speak(_:)`, in call order.
    nonisolated(unsafe) private(set) var spokenUtterances: [AVSpeechUtterance] = []
    /// Number of `stopSpeaking(at:)` calls.
    nonisolated(unsafe) private(set) var stopCount = 0
    /// Requested pause boundaries and resume calls, including refused requests.
    nonisolated(unsafe) private(set) var pauseBoundaries: [AVSpeechBoundary] = []
    nonisolated(unsafe) private(set) var continueCount = 0
    var pauseResult = true
    var continueResult = true
    /// Optional synchronous delegate acknowledgements for accepted requests.
    var onPause: (() -> Void)?
    var onContinue: (() -> Void)?
    /// Synchronous state changes that occur while a continuation result is pending.
    var onContinueAttempt: (() -> Void)?

    /// The spoken verses' text, in order — the readable assertion target.
    var spokenTexts: [String] { spokenUtterances.map(\.speechString) }
    /// The most recently queued utterance, the one a test fires
    /// `didStart` / `didFinish` against.
    var lastUtterance: AVSpeechUtterance? { spokenUtterances.last }

    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
    }

    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCount += 1
        return true
    }

    @discardableResult
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        pauseBoundaries.append(boundary)
        if pauseResult { onPause?() }
        return pauseResult
    }

    @discardableResult
    func continueSpeaking() -> Bool {
        continueCount += 1
        let result = continueResult
        onContinueAttempt?()
        if result { onContinue?() }
        return result
    }
}
