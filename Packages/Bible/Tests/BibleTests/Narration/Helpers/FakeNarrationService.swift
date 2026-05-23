import AVFoundation
import Foundation
@testable import Bible

/// In-memory ``NarrationService`` test double. Tests drive the active
/// session by calling `emit(_:)` / `finish(with:)` from the test body;
/// callers inspect the recorded call counts and `lastStartArgs` to assert
/// what the controller scheduled.
///
/// Strict by design: each call records into a counter so a regression
/// that double-starts a session (or stops twice) shows up as an exact
/// assertion failure rather than a vague flake.
final class FakeNarrationService: NarrationService, @unchecked Sendable {
    private let lock = NSLock()
    private var _isAvailableValue: Bool = true
    private var _startCallCount = 0
    private var _pauseCallCount = 0
    private var _resumeCallCount = 0
    private var _stopCallCount = 0
    private var _skipForwardCallCount = 0
    private var _skipBackwardCallCount = 0
    private var _skipToPreviousVerseCallCount = 0
    private var _setRateCalls: [Float] = []
    private var _setVoiceCalls: [AVSpeechSynthesisVoice?] = []
    private var _lastStartArgs: StartArgs?
    private var continuation: AsyncStream<NarrationEvent>.Continuation?

    struct StartArgs: Equatable {
        let utterances: [NarrationVerseUtterance]
        let rate: Float
        // AVSpeechSynthesisVoice doesn't conform to Equatable; tests
        // inspect by `voice?.identifier` when they need to assert it.
        let voiceIdentifier: String?
    }

    // MARK: Configurable knobs

    var isAvailableValue: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isAvailableValue }
        set { lock.lock(); _isAvailableValue = newValue; lock.unlock() }
    }

    // MARK: Recorded calls

    var startCallCount: Int { lock.lock(); defer { lock.unlock() }; return _startCallCount }
    var pauseCallCount: Int { lock.lock(); defer { lock.unlock() }; return _pauseCallCount }
    var resumeCallCount: Int { lock.lock(); defer { lock.unlock() }; return _resumeCallCount }
    var stopCallCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCallCount }
    var skipForwardCallCount: Int { lock.lock(); defer { lock.unlock() }; return _skipForwardCallCount }
    var skipBackwardCallCount: Int { lock.lock(); defer { lock.unlock() }; return _skipBackwardCallCount }
    var skipToPreviousVerseCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _skipToPreviousVerseCallCount
    }
    var setRateCalls: [Float] { lock.lock(); defer { lock.unlock() }; return _setRateCalls }
    var setVoiceCalls: [AVSpeechSynthesisVoice?] { lock.lock(); defer { lock.unlock() }; return _setVoiceCalls }
    var lastStartArgs: StartArgs? { lock.lock(); defer { lock.unlock() }; return _lastStartArgs }

    // MARK: NarrationService

    func isAvailable() -> Bool { isAvailableValue }

    func startSpeaking(
        _ utterances: [NarrationVerseUtterance],
        rate: Float,
        voice: AVSpeechSynthesisVoice?
    ) -> AsyncStream<NarrationEvent> {
        let args = StartArgs(
            utterances: utterances,
            rate: rate,
            voiceIdentifier: voice?.identifier
        )
        lock.lock()
        _startCallCount += 1
        _lastStartArgs = args
        // Close any prior session's continuation so the prior stream's
        // consumer task drops cleanly — production behaviour for a second
        // start while already speaking.
        let previous = continuation
        continuation = nil
        lock.unlock()
        previous?.finish()

        return AsyncStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuation = nil
                self.lock.unlock()
            }
        }
    }

    func pause() { lock.lock(); _pauseCallCount += 1; lock.unlock() }
    func resume() { lock.lock(); _resumeCallCount += 1; lock.unlock() }
    func stop() { lock.lock(); _stopCallCount += 1; lock.unlock() }
    func skipForward() { lock.lock(); _skipForwardCallCount += 1; lock.unlock() }
    func skipBackward() { lock.lock(); _skipBackwardCallCount += 1; lock.unlock() }
    func skipToPreviousVerse() {
        lock.lock(); _skipToPreviousVerseCallCount += 1; lock.unlock()
    }
    func setRate(_ rate: Float) { lock.lock(); _setRateCalls.append(rate); lock.unlock() }
    func setVoice(_ voice: AVSpeechSynthesisVoice?) {
        lock.lock(); _setVoiceCalls.append(voice); lock.unlock()
    }

    // MARK: Test driving helpers

    /// Yield `event` into the active stream. No-op if no session is open.
    func emit(_ event: NarrationEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    /// Yield `terminal` (must be `.completed` / `.cancelled` / `.failed`)
    /// then close the stream — mirrors how the real service ends a
    /// session.
    func finish(with terminal: NarrationEvent) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.yield(terminal)
        continuation?.finish()
    }
}

/// Bridge that captures the controller's `onCompletion` callback into a
/// recorder readable from the test body without `Task` hops.
@MainActor
final class CompletionRecorder {
    private(set) var firedCount = 0
    func record() { firedCount += 1 }
}

/// Mutable `Date` source for tests that need to drive controller
/// behaviour past a time-based threshold (e.g. the double-tap window).
/// Production code injects `{ Date() }`; tests pass `{ clock.now }`
/// against an instance of this and call ``advance(by:)`` to move time
/// forward deterministically.
@MainActor
final class TestClock {
    private(set) var now: Date

    init(start: Date = Date(timeIntervalSince1970: 1_000_000_000)) {
        self.now = start
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
