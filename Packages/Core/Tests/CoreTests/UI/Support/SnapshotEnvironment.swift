import Foundation

/// Snapshot-test helpers shared across `CoreTests` UI suites. Mirrors
/// `Packages/Chat/Tests/.../Support/SnapshotEnvironment.swift` so the
/// recording gate behaves identically across the project: set
/// `SNAPSHOT_RECORD=1` (or `TEST_RUNNER_SNAPSHOT_RECORD=1` under
/// `xcodebuild test` so the variable crosses into the simulator-hosted
/// runner). CI must leave it unset so any mismatch fails the build.
enum SnapshotEnvironment {
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"
    }
}
