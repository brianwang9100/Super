import Foundation

/// Snapshot-test helpers shared across UI test suites. Mirrors the Chat
/// package's `SnapshotEnvironment` so the same `SNAPSHOT_RECORD` env var
/// gates recording across both packages.
///
/// Recording is gated by the `SNAPSHOT_RECORD` env var, but the way you set
/// it depends on the runner:
///   - `xcodebuild test` against an iOS simulator: prefix with
///     `TEST_RUNNER_` so xcodebuild forwards it into the test process
///     (`TEST_RUNNER_SNAPSHOT_RECORD=1 xcodebuild test …`).
///   - Xcode's Test action: set `SNAPSHOT_RECORD=1` in the scheme's Test
///     environment variables.
/// CI must leave the variable unset so any mismatch fails the build.
enum SnapshotEnvironment {
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"
    }
}
