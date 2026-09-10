import AVFoundation
@testable import Bible

/// Tests drive delegate callbacks manually; no audio playback occurs.
final class FakeSpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?

    // Tests access these recorders synchronously on one thread.
    nonisolated(unsafe) private(set) var spokenUtterances: [AVSpeechUtterance] = []
    nonisolated(unsafe) private(set) var stopCount = 0
    /// Includes refused pause/resume requests.
    nonisolated(unsafe) private(set) var pauseBoundaries: [AVSpeechBoundary] = []
    nonisolated(unsafe) private(set) var continueCount = 0
    var pauseResult = true
    var continueResult = true
    /// Optional synchronous delegate acknowledgements for accepted requests.
    var onPause: (() -> Void)?
    var onContinue: (() -> Void)?
    /// Synchronous state changes that occur while a continuation result is pending.
    var onContinueAttempt: (() -> Void)?

    var spokenTexts: [String] { spokenUtterances.map(\.speechString) }
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
