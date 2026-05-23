import AVFoundation
import Foundation
import os
@testable import Bible

/// In-memory ``NarrationService`` test double. Tests drive the active
/// session by calling `emit(_:)` / `finish(with:)` from the test body;
/// callers inspect the recorded call counts and `lastStartArgs` to assert
/// what the controller scheduled.
///
/// Strict by design: each call records into a counter so a regression
/// that double-starts a session (or stops twice) shows up as an exact
/// assertion failure rather than a vague flake.
///
/// Synchronization uses ``OSAllocatedUnfairLock`` rather than `NSLock`
/// per root AGENTS.md "Synchronization" rules — test doubles follow
/// the same lock policy as production code.
final class FakeNarrationService: NarrationService, @unchecked Sendable {
    /// Mutable state, gated by `lock`. Bundled as a struct so multi-
    /// field mutations (e.g. record-then-rotate-continuation in
    /// `startSpeaking`) land atomically in a single `withLock`.
    private struct FakeState {
        var isAvailableValue: Bool = true
        var startCallCount = 0
        var pauseCallCount = 0
        var resumeCallCount = 0
        var stopCallCount = 0
        var skipForwardCallCount = 0
        var skipBackwardCallCount = 0
        var skipToPreviousVerseCallCount = 0
        var setRateCalls: [Float] = []
        var setVoiceCalls: [AVSpeechSynthesisVoice?] = []
        var lastStartArgs: StartArgs?
        var continuation: AsyncStream<NarrationEvent>.Continuation?
    }

    private let lock = OSAllocatedUnfairLock(initialState: FakeState())

    struct StartArgs: Equatable {
        let utterances: [NarrationVerseUtterance]
        let rate: Float
        // AVSpeechSynthesisVoice doesn't conform to Equatable; tests
        // inspect by `voice?.identifier` when they need to assert it.
        let voiceIdentifier: String?
    }

    // MARK: Configurable knobs

    var isAvailableValue: Bool {
        get { lock.withLock { $0.isAvailableValue } }
        set { lock.withLock { $0.isAvailableValue = newValue } }
    }

    // MARK: Recorded calls

    var startCallCount: Int { lock.withLock { $0.startCallCount } }
    var pauseCallCount: Int { lock.withLock { $0.pauseCallCount } }
    var resumeCallCount: Int { lock.withLock { $0.resumeCallCount } }
    var stopCallCount: Int { lock.withLock { $0.stopCallCount } }
    var skipForwardCallCount: Int { lock.withLock { $0.skipForwardCallCount } }
    var skipBackwardCallCount: Int { lock.withLock { $0.skipBackwardCallCount } }
    var skipToPreviousVerseCallCount: Int { lock.withLock { $0.skipToPreviousVerseCallCount } }
    var setRateCalls: [Float] { lock.withLock { $0.setRateCalls } }
    var setVoiceCalls: [AVSpeechSynthesisVoice?] { lock.withLock { $0.setVoiceCalls } }
    var lastStartArgs: StartArgs? { lock.withLock { $0.lastStartArgs } }

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
        // Atomically record the start and snapshot the prior
        // continuation so it can be finished outside the lock.
        let previous: AsyncStream<NarrationEvent>.Continuation? = lock.withLock { state in
            state.startCallCount += 1
            state.lastStartArgs = args
            let prior = state.continuation
            state.continuation = nil
            return prior
        }
        previous?.finish()

        return AsyncStream { continuation in
            self.lock.withLock { $0.continuation = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { $0.continuation = nil }
            }
        }
    }

    func pause() { lock.withLock { $0.pauseCallCount += 1 } }
    func resume() { lock.withLock { $0.resumeCallCount += 1 } }
    func stop() { lock.withLock { $0.stopCallCount += 1 } }
    func skipForward() { lock.withLock { $0.skipForwardCallCount += 1 } }
    func skipBackward() { lock.withLock { $0.skipBackwardCallCount += 1 } }
    func skipToPreviousVerse() {
        lock.withLock { $0.skipToPreviousVerseCallCount += 1 }
    }
    func setRate(_ rate: Float) { lock.withLock { $0.setRateCalls.append(rate) } }
    func setVoice(_ voice: AVSpeechSynthesisVoice?) {
        lock.withLock { $0.setVoiceCalls.append(voice) }
    }

    // MARK: Test driving helpers

    /// Yield `event` into the active stream. No-op if no session is open.
    /// Stream-based tests use this then `await
    /// controller._waitForPendingStreamTask()` for the stream's
    /// terminal events; for mid-session events tests should prefer
    /// `controller._simulateEvent(_:)` for deterministic timing.
    func emit(_ event: NarrationEvent) {
        let continuation = lock.withLock { $0.continuation }
        continuation?.yield(event)
    }

    /// Yield `terminal` (must be `.completed` / `.cancelled` / `.failed`)
    /// then close the stream — mirrors how the real service ends a
    /// session.
    func finish(with terminal: NarrationEvent) {
        let continuation: AsyncStream<NarrationEvent>.Continuation? = lock.withLock { state in
            let c = state.continuation
            state.continuation = nil
            return c
        }
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
