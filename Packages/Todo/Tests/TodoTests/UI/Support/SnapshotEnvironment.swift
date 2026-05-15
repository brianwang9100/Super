import Foundation

/// Snapshot-test helpers shared across the Todo UI test suites.
///
/// Recording is gated by the `SNAPSHOT_RECORD` env var, but the way you set
/// it depends on the runner:
///   - `xcodebuild test` against an iOS simulator: prefix with
///     `TEST_RUNNER_` so xcodebuild forwards it into the test process
///     (`TEST_RUNNER_SNAPSHOT_RECORD=1 xcodebuild test …`). A bare
///     `SNAPSHOT_RECORD=1` lives in xcodebuild's environment but never
///     reaches the simulator-hosted xctest runner.
///   - Xcode's Test action: set `SNAPSHOT_RECORD=1` in the scheme's Test
///     environment variables.
/// CI must leave the variable unset so any mismatch fails the build. Per
/// `AGENTS.md` §Testing, snapshots are only re-recorded when a visual
/// change is intentional and explained in the PR.
enum SnapshotEnvironment {
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"
    }
}
