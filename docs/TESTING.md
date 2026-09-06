# Testing

Read this before adding tests, changing SwiftUI views, recording snapshots, or verifying on a simulator. These are Super's test requirements and fixture conventions.

## Required coverage

| Change | Required verification |
|---|---|
| New logic | Unit tests with injected dependencies |
| Bug fix | Regression that fails before the fix; explain any unavailable regression in the PR |
| GRDB schema/query | In-memory `DatabaseQueue` integration test; `GRDBSnapshotTesting` when schema shape matters |
| Cross-applet event/tool | Exercise a real in-memory `SuperEventBus` |
| SwiftUI view | Snapshot key applicable states in Vellum light/dark at default Dynamic Type; add XXL for text reflow, Reduce Motion for animation, and each supported form factor for applet layouts |

Coverage floors remain Core ≥80%, applets ≥70%, and future server ≥80%; do not lower them. The workflows currently print Swift coverage summaries; Codecov gating remains planned.

Before opening a PR, run `swift test` from **each affected package root**. This excludes UIKit snapshot suites on macOS, so changed views also require the simulator run below. Record tests and results in the [PR template](../.github/pull_request_template.md)'s **Test Coverage** section. Documentation-only changes need link/diff checks, not app test runs.

## Async fixture conventions

- No `Task.yield()` polling or `Task.sleep` synchronization. Use `_waitFor…()` seams that await task completion, processed-event signals, or synchronous `_simulateEvent(_:)` seams. Drain all mutated state before assertions; drain parent tasks before the children they spawn.
- When concurrent operations consume an order-sensitive script, await the first operation's entry signal before starting the next (`PermissionGate.waitUntilEntered()`, tool `awaitFirstCall()`).
- Match strict doubles such as `FakeLLMProvider`: unexpected calls or exhausted scripts fail at the caller. Record main-actor callbacks synchronously in a `@MainActor` spy, not a spawned task.
- Do not serialize logic suites to mask races. The snapshot recording exception is below. Reuse Core's `FixedClock`/`DeterministicIDGenerator`; do not create local copies.

Package `AGENTS.md` files identify their local fixtures and drain seams.

## Snapshot conventions

Every UIKit view snapshot suite requires all three, even for glyph-only/system-font views:

1. `#if canImport(UIKit)` around the suite.
2. `init { SnapshotFontRegistration.ensureRegistered() }` in the suite.
3. `record: SnapshotEnvironment.isRecording ? .all : nil` in assertions.

Font registration in every suite makes rendering independent of suite order. Database schema snapshots render no views and are exempt.

- Per-screen suites cover only `vellumLight`/`vellumDark`. `ThemeGallerySnapshotTests` covers the other theme families once per package; don't fan every screen out over `SuperTheme.Identifier.allCases`.
- Snapshot serialization is module-consistent: Chat/Todo serialize to guard recording writes; Bible/Core do not. State the recording rationale in one comment, and document any local opt-out. Serialization does not replace font registration.
- Re-record only intentional visual changes. For font-scale changes alone, the 1.0× render stays byte-identical; maximum-scale baselines change with the slider. The two exempt fixed brand marks remain identical across slider values.
- The only sanctioned custom-font anti-aliasing tolerance is `precision: 0.99`, `perceptualPrecision: 0.97`, defined as a named constant with the reason. Never use it to conceal structural drift.

## Simulator environment

The source of truth is [ios-build.yml](../.github/workflows/ios-build.yml)'s Xcode selection and **Pick iOS simulator** step. Its current pins are Xcode **26.4.1**, iOS **26.4.1 / `23E254a`**, and **iPhone 17**. Match the exact Xcode build and runtime build before recording, not just the iOS minor version. Coordinate pin changes with CI and baselines; don't switch to a beta runner toolchain.

```bash
xcodebuild -version
xcrun simctl list runtimes iOS
xcrun simctl runtime list
```

Both `23E244` and `23E254a` report as iOS 26.4 and share the simulator runtime identifier. Keep only the CI build installed for that minor; otherwise `OS=26.4` can select the wrong renderer. The local [snapshot guard](../.codex/hooks/enforce-snapshot-sim.py) checks this against the workflow pins.

Use a dedicated **per-worktree** simulator for tests and manual verification, never a shared booted device. From the repository root:

```bash
xcodegen generate
SIM_ID=$(xcrun simctl create "SB-$(basename "$PWD")-$(basename "$(dirname "$PWD")")" \
  "iPhone 17" com.apple.CoreSimulator.SimRuntime.iOS-26-4)
xcrun simctl boot "$SIM_ID"
xcrun simctl bootstatus "$SIM_ID" -b
xcodebuild test -scheme Chat \
  -destination "platform=iOS Simulator,id=$SIM_ID"
```

Reuse that simulator for this worktree's later runs; substitute Core/Bible/Todo for the package under test. Package test schemes live in `Scripts/xcodegen-extras/` and are copied by `project.yml`'s post-generation command.

For intentional recording, prefix the test command with `TEST_RUNNER_SNAPSHOT_RECORD=1`. The `TEST_RUNNER_` prefix forwards the variable into the iOS test process.

If the CI runtime is unavailable, document the exact mismatch and mitigation in the PR. Defer an affected variant with a stated reason, or use the sanctioned tolerance only for sub-pixel custom-font drift. Never bless structural differences as a new baseline.

After verifying the PR is `MERGED`, shut down and delete **only this worktree's simulator**. Keep the worktree and local branch, per [AGENTS.md](../AGENTS.md#worktree-discipline).

## App-target verification

There is currently no app-target XCTest target. Snapshot package-owned surfaces in their packages, and manually verify app-only wiring/layout on the dedicated CI-matching simulator. This is the exception to the view snapshot requirement, not a substitute for existing package coverage.

Shared shell changes must build both `Super` and `SuperBible` locally before a PR. Target-only changes build the affected scheme:

```bash
xcodebuild build -scheme Super \
  -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme SuperBible \
  -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO
```
