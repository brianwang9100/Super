import AVFoundation
import Foundation
import os
@testable import Bible

/// Drive sessions with emit/finish; exact call counts expose duplicate controller operations.
final class FakeNarrationService: NarrationService, @unchecked Sendable {
    // One lock protects multi-field session transitions atomically.
    private struct FakeState {
        var isAvailableValue: Bool = true
        var voiceLookupLocales: [Locale] = []
        var startCallCount = 0
        var pauseCallCount = 0
        var resumeCallCount = 0
        var stopCallCount = 0
        var skipForwardCallCount = 0
        var skipBackwardCallCount = 0
        var skipToPreviousVerseCallCount = 0
        var setRateCalls: [Float] = []
        var setVoiceCalls: [NarrationVoice?] = []
        var lastStartArgs: StartArgs?
        var continuation: AsyncStream<NarrationEvent>.Continuation?
    }

    private let lock = OSAllocatedUnfairLock(initialState: FakeState())

    struct StartArgs: Equatable {
        let utterances: [NarrationVerseUtterance]
        let rate: Float
        let startingAt: Int
        let voiceIdentifier: String?
    }

    // MARK: Configurable knobs

    var isAvailableValue: Bool {
        get { lock.withLock { $0.isAvailableValue } }
        set { lock.withLock { $0.isAvailableValue = newValue } }
    }

    // MARK: Recorded calls

    var voiceLookupLocales: [Locale] { lock.withLock { $0.voiceLookupLocales } }
    var startCallCount: Int { lock.withLock { $0.startCallCount } }
    var pauseCallCount: Int { lock.withLock { $0.pauseCallCount } }
    var resumeCallCount: Int { lock.withLock { $0.resumeCallCount } }
    var stopCallCount: Int { lock.withLock { $0.stopCallCount } }
    var skipForwardCallCount: Int { lock.withLock { $0.skipForwardCallCount } }
    var skipBackwardCallCount: Int { lock.withLock { $0.skipBackwardCallCount } }
    var skipToPreviousVerseCallCount: Int { lock.withLock { $0.skipToPreviousVerseCallCount } }
    var setRateCalls: [Float] { lock.withLock { $0.setRateCalls } }
    var setVoiceCalls: [NarrationVoice?] { lock.withLock { $0.setVoiceCalls } }
    var lastStartArgs: StartArgs? { lock.withLock { $0.lastStartArgs } }

    // MARK: NarrationService

    func isAvailable() -> Bool { isAvailableValue }

    func bestAvailableVoice(locale: Locale) -> NarrationVoice? {
        lock.withLock { $0.voiceLookupLocales.append(locale) }
        return nil
    }

    func startSpeaking(
        _ utterances: [NarrationVerseUtterance],
        rate: Float,
        voice: NarrationVoice?,
        startingAt: Int = 0
    ) -> AsyncStream<NarrationEvent> {
        let args = StartArgs(
            utterances: utterances,
            rate: rate,
            startingAt: startingAt,
            voiceIdentifier: voice?.identifier
        )
        // Finish the prior continuation outside the lock after atomically rotating sessions.
        let previous: AsyncStream<NarrationEvent>.Continuation? = lock.withLock { state in
            state.startCallCount += 1
            state.lastStartArgs = args
            let prior = state.continuation
            state.continuation = nil
            return prior
        }
        // Match production: buffer a terminal event in the old stream before closing it.
        // This exposes stale-consumer races during session replacement.
        previous?.yield(.cancelled)
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
    func setVoice(_ voice: NarrationVoice?) {
        lock.withLock { $0.setVoiceCalls.append(voice) }
    }

    // MARK: Test driving helpers

    /// No-op without a session. Drain terminal events with _waitForPendingStreamTask;
    /// use _simulateEvent for synchronous mid-session assertions.
    func emit(_ event: NarrationEvent) {
        let continuation = lock.withLock { $0.continuation }
        continuation?.yield(event)
    }

    /// Emit a terminal completed/cancelled/failed event and close the stream.
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

@MainActor
final class CompletionRecorder {
    private(set) var firedCount = 0
    func record() { firedCount += 1 }
}

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
