import Core
import os

/// Records plays even while disabled; production owns enablement filtering.
final class RecordingHapticsEngine: HapticsEngine {
    private struct State {
        var played: [HapticPattern] = []
        var enabledLog: [Bool] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @MainActor func play(_ pattern: HapticPattern) {
        state.withLock { $0.played.append(pattern) }
    }

    @MainActor func setEnabled(_ enabled: Bool) {
        state.withLock { $0.enabledLog.append(enabled) }
    }

    var played: [HapticPattern] {
        state.withLock { $0.played }
    }

    var enabledLog: [Bool] {
        state.withLock { $0.enabledLog }
    }
}
