import Foundation

/// Snapshot-test helpers shared across UI test suites.
///
/// Recording is gated by the `SNAPSHOT_RECORD` env var (set to `1` at
/// invocation time, e.g. `SNAPSHOT_RECORD=1 xcodebuild test …`). CI must
/// leave the variable unset so any mismatch fails the build. Per
/// `AGENTS.md` §Testing, snapshots are only re-recorded when a visual
/// change is intentional and explained in the PR.
enum SnapshotEnvironment {
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"
    }
}
