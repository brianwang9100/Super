import Core
import os

final class RecordingHapticsEngine: HapticsEngine {
    private let playedState = OSAllocatedUnfairLock<[HapticPattern]>(initialState: [])

    @MainActor func play(_ pattern: HapticPattern) {
        playedState.withLock { $0.append(pattern) }
    }

    @MainActor func setEnabled(_ enabled: Bool) {}

    var played: [HapticPattern] {
        playedState.withLock { $0 }
    }
}
