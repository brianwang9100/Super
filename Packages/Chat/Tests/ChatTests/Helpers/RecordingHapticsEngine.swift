import Core
import os

/// Test double that records every `HapticPattern` played (and every
/// `setEnabled` call) so a test can assert which haptics a view model fired
/// and in what order. Thread-safe via `os_unfair_lock` (the `FixedClock`
/// pattern) so it satisfies `HapticsEngine: Sendable` without a `@MainActor`
/// hop. `play(_:)` always records — the enabled gate is the production
/// engine's concern, not the spy's.
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

    /// Every pattern played, in order.
    var played: [HapticPattern] {
        state.withLock { $0.played }
    }

    /// Every `setEnabled` argument, in order.
    var enabledLog: [Bool] {
        state.withLock { $0.enabledLog }
    }
}
