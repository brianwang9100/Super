import Core
import os

/// Test double that records every `HapticPattern` played so a test can assert
/// which haptics a view model fired and in what order. Thread-safe via
/// `os_unfair_lock` (the `FixedClock` pattern) so it satisfies
/// `HapticsEngine: Sendable` without a `@MainActor` hop.
final class RecordingHapticsEngine: HapticsEngine {
    private let playedState = OSAllocatedUnfairLock<[HapticPattern]>(initialState: [])

    func play(_ pattern: HapticPattern) {
        playedState.withLock { $0.append(pattern) }
    }

    func setEnabled(_ enabled: Bool) {}

    /// Every pattern played, in order.
    var played: [HapticPattern] {
        playedState.withLock { $0 }
    }
}
