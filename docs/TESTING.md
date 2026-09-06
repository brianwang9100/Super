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

Network, database, filesystem, HomeKit, and Keychain side effects need injectable interfaces, including within applets; avoid static singletons and hidden globals. Tests must be able to substitute those dependencies.

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
SIM_ID=$(python3 Scripts/worktree_simulator.py ensure)
xcrun simctl boot "$SIM_ID"
xcrun simctl bootstatus "$SIM_ID" -b
xcodebuild test -scheme Chat \
  -destination "platform=iOS Simulator,id=$SIM_ID"
```

`ensure` creates once and returns the same UUID on later runs; it does not boot the device. Skip `boot` when it is already booted. Substitute Core/Bible/Todo for the package under test. Package test schemes live in `Scripts/xcodegen-extras/` and are copied by `project.yml`'s post-generation command.

For intentional recording, prefix the test command with `TEST_RUNNER_SNAPSHOT_RECORD=1`. The `TEST_RUNNER_` prefix forwards the variable into the iOS test process.

If the CI runtime is unavailable, document the exact mismatch and mitigation in the PR. Defer an affected variant with a stated reason, or use the sanctioned tolerance only for sub-pixel custom-font drift. Never bless structural differences as a new baseline.

## Worktree simulator lifecycle

Associate a worktree on first use with [worktree_simulator.py](../Scripts/worktree_simulator.py) `ensure`. It reads CI's Xcode/device/runtime pins and records the simulator UUID, owner path, and Git identity under the common Git directory's `worktree-simulators/registry.json`. This state survives individual worktree deletion. Managed names start with `SuperWT-`; ownership comes from the registry, never a name-prefix guess. Existing unregistered simulators are left alone.

After `gh pr view <N> --json state` confirms `MERGED`, a clean worktree may be removed with `git worktree remove <path>` from a surviving checkout. Check for uncommitted/untracked work first; do not force removal. Retaining the worktree also retains its simulator. After removal, run from the surviving checkout:

```bash
python3 Scripts/worktree_simulator.py cleanup          # preview registered orphans
python3 Scripts/worktree_simulator.py cleanup --apply  # shut down and delete them
```

Cleanup preserves moved worktrees through their Git identity, rechecks owner paths before deletion, and stops on ambiguous ownership or unreadable state. It never removes worktrees or unregistered simulators. The same commands support `--repo /path/to/surviving/Super` when invoked outside the checkout.

Daily scheduled cleanup should run against the durable main checkout. Use the checked-in helper there after merge; until it is available, install a reviewed copy at the common Git directory's `worktree-simulators/worktree_simulator.py`. Both use the same registry. Run preview before apply, report failures or deletions, and stay quiet when nothing changes. The Codex app and Mac must be running for local scheduled tasks to execute.

Helper/guard regression tests: `python3 -B -m unittest discover -s Scripts/tests -v` and `bash .codex/hooks/tests/test-hooks.sh`.

## App-target verification

There is currently no app-target XCTest target. Snapshot package-owned surfaces in their packages, and manually verify app-only wiring/layout on the dedicated CI-matching simulator. This is the exception to the view snapshot requirement, not a substitute for existing package coverage.

Shared shell changes must build both `Super` and `SuperBible` locally before a PR. Target-only changes build the affected scheme:

```bash
xcodebuild build -scheme Super \
  -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme SuperBible \
  -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO
```
