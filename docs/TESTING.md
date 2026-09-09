# Testing

Read this before adding tests, changing SwiftUI views, capturing visual fixtures, or verifying on a simulator. These are Super's test requirements and fixture conventions.

## Required coverage

| Change | Required verification |
|---|---|
| New logic | Unit tests with injected dependencies |
| Bug fix | Regression that fails before the fix; explain any unavailable regression in the PR |
| GRDB schema/query | In-memory `DatabaseQueue` integration test; `GRDBSnapshotTesting` when schema shape matters |
| Cross-applet event/tool | Exercise a real in-memory `SuperEventBus` |
| SwiftUI view | Cover distinct visual risks through existing or new screen/gallery captures; follow [VISUAL_TESTING_POLICY.md](VISUAL_TESTING_POLICY.md) for state, theme, accessibility, and form-factor selection |

Coverage floors remain Core ≥80%, applets ≥70%, and future server ≥80%; do not lower them. Argos's package driver builds once with coverage, enumerates the complete test target, and runs each discovered visual suite in isolation. A complementary logic execution excludes exactly those suites. `Scripts/ios_coverage.py` validates the complete test union and unions raw executable physical source-line hits from these same-source/same-build results. It rejects missing, duplicate, failed or mismatched evidence and retains skips and expanded parameterized executions. Native aggregate percentages and macOS SwiftPM coverage remain separate diagnostics; percentages are never averaged or added. Codecov integration remains planned. Argos's sole `ios-test` aggregate requires both package capture and coverage outcomes.

Successful and failed simulator legs retain the result bundle, raw coverage, exact test/skip inventory, toolchain/runtime identity, and source hashes. A failed/empty/incomplete test run cannot satisfy coverage. Uninstrumented source/resource files remain disclosed in the evidence instead of being silently hidden or counted as fictitious executable lines. Changes to the measurement require reviewed fixtures; green test counts alone do not establish compliance.

Network, database, filesystem, HomeKit, and Keychain side effects need injectable interfaces, including within applets; avoid static singletons and hidden globals. Tests must be able to substitute those dependencies.

Before opening a PR, run `swift test` from **each affected package root**. This excludes UIKit snapshot suites on macOS, so changed views also require the simulator run below. Record tests and results in the [PR template](../.github/pull_request_template.md)'s **Test Coverage** section. Documentation-only changes need link/diff checks, not app test runs.

## Async fixture conventions

- No `Task.yield()` polling or `Task.sleep` synchronization. Use `_waitFor…()` seams that await task completion, processed-event signals, or synchronous `_simulateEvent(_:)` seams. Drain all mutated state before assertions; drain parent tasks before the children they spawn.
- When concurrent operations consume an order-sensitive script, await the first operation's entry signal before starting the next (`PermissionGate.waitUntilEntered()`, tool `awaitFirstCall()`).
- Match strict doubles such as `FakeLLMProvider`: unexpected calls or exhausted scripts fail at the caller. Record main-actor callbacks synchronously in a `@MainActor` spy, not a spawned task.
- Do not serialize logic suites to mask races. The visual capture serialization requirement is below. Reuse Core's `FixedClock`/`DeterministicIDGenerator`; do not create local copies.

Package `AGENTS.md` files identify their local fixtures and drain seams.

## Visual coverage selection

- **New or changed SwiftUI view** → **cover the visual risk, not every view declaration.** Reuse an existing screen or component-gallery scenario when it visibly exercises the change. Add a screenshot only for a distinct layout, theme, reflow, or visual regression risk that existing coverage misses; behavior, data permutations, and state transitions belong in unit/integration tests. Follow [VISUAL_TESTING_POLICY.md](VISUAL_TESTING_POLICY.md).
- **Keep the visual matrix small.** Use Vellum light/dark for a representative primary layout; cover additional states in one theme unless they introduce a separate color/contrast risk. Add XXL, app font-scale extremes, Reduce Motion, and another form factor only where they exercise distinct behavior. Keep a representative reflow case for text-heavy surfaces, known visual regression cases, and each distinct applet-level iPhone/iPad/Mac layout. Do not multiply every state by every axis. All eight palettes belong in the existing package theme galleries, not every screen suite.
- **Every new screenshot needs a reason.** In the PR's Test Coverage section, name the scenario, the defect it would catch, why an existing capture is insufficient, and the before/after screenshot count. Prefer a small readable component gallery over separate captures of every pill, icon, or toggle. Byte-identical baselines are audit candidates, not proof that their input cases are redundant; retain behavioral assertions and investigate ineffective fixtures before removing coverage.
- **Argos owns image baselines.** The complete inventory contains 652 images: 604 package fixtures and 48 native previews. Package fixtures retain their Point-Free image strategies through the test-only `VisualTestSupport` exporter; generated PNGs stay ignored. Do not record or commit local image baselines. GRDB/text snapshots and behavioral assertions remain independent. Approve only intentional visual changes in Argos, never simply to make a check pass.

## Visual fixture conventions

Every UIKit visual suite requires:

1. `#if canImport(UIKit)` around the suite.
2. `init { SnapshotFontRegistration.ensureRegistered() }` in the suite.
3. `import VisualTestSupport` and `verifyVisualSnapshot` with the existing image strategy and explicit stable name.
4. A `.serialized` suite. The capture driver also disables parallel simulator testing and runs one suite at a time to isolate shared UIKit rendering state.

Font registration in every suite makes rendering independent of suite order. Database schema snapshots render no views and are exempt. Keep the existing size, traits, drawing method, font registration, and behavioral assertions when changing a fixture. The Point-Free dependency is a test-only renderer; Argos performs image comparison. Local recording flags and precision tolerances do not approve Argos changes.

Per-screen suites use Vellum light/dark for primary layouts. `ThemeGallerySnapshotTests` owns the other theme families; do not fan every screen out over `SuperTheme.Identifier.allCases`. Register any approved new capture in the tracked inventory. Parameterized visual states need distinct stable names; four existing Bible reader fixtures previously shared filenames between open and dismissed action states, and now retain both outputs. Missing, duplicate, unexpected, corrupt, or wrong-sized images fail capture validation.

## Simulator environment

The source of truth is [simulator-pins.json](../Scripts/VisualTesting/simulator-pins.json), shared by both capture drivers, the worktree simulator helper, and the local guard. Current pins are Xcode **27.0 beta 6 / `27A5252f`**, XcodeGen **2.45.4**, iOS **27.0 / `24A5423a`**, and **iPhone 17**. Match the exact toolchain and runtime builds. Coordinate pin changes with CI and Argos review.

```bash
xcodebuild -version
xcrun simctl list runtimes iOS
xcrun simctl runtime list
```

Different beta builds can share the `iOS-27-0` runtime identifier. Verify both `simctl list runtimes --json` and `simctl runtime list`; `OS=27.0` alone cannot distinguish them. Use a literal per-command `DEVELOPER_DIR` when the global Xcode selection differs. The simulator guard fails closed if the exact compiler/runtime/device cannot be verified. Xcode 27 requires macOS 26.4 or later; do not change the host or global toolchain without authorization.

Use a dedicated **per-worktree** simulator for tests and manual verification, never a shared booted device. The capture drivers call `python3 Scripts/worktree_simulator.py ensure` and reuse its registered UUID. Local visual commands, from the repository root:

```bash
npm ci
python3 -m pip install -r Scripts/VisualTesting/requirements.txt
npm test                              # full 652-image capture and validation
npm run test:visual:native             # native 48-image subset
python3 Scripts/VisualTesting/capture.py Chat --output .build/chat-visual-capture
```

The package command exports coverage evidence under its run directory. Enforce its unchanged floor with `python3 Scripts/ios_coverage.py --evidence .build/VisualTesting/run-PACKAGE-ID/coverage`. A capture can complete below the floor; the separate coverage job then fails `ios-test`. The package command requires a fresh output directory; substitute Bible/Core/Todo as needed. It builds once and runs the serialized visual suites individually. Bundles contain `images/` and `capture.json`; logs and result bundles live under `.build/VisualTesting/`. Normal view iteration can use targeted capture or Xcode previews; CI renders the complete inventory on every PR, including documentation changes. A full local render is required for capture-infrastructure changes and useful for diagnosing rendering; ordinary code changes still require the affected package's local unit/integration/database tests and relevant simulator coverage.

For simulator logic tests or app verification:

```bash
xcodegen generate
SIM_ID=$(python3 Scripts/worktree_simulator.py ensure)
xcrun simctl boot "$SIM_ID"
xcrun simctl bootstatus "$SIM_ID" -b
xcodebuild test -scheme Chat \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -parallel-testing-enabled NO
```

`ensure` creates once and returns the same UUID on later runs; it does not boot the device. Skip `boot` when it is already booted. Package test schemes live in `Scripts/xcodegen-extras/` and are copied by `project.yml`'s post-generation command. Use the capture driver when exporting images; direct tests do not produce a complete validated Argos bundle.

If the pinned environment is unavailable, report the exact mismatch and missing verification in the PR. Do not approve a different renderer's output as a substitute for the required capture.

For older-runtime app compatibility only, `SUPER_IOS_COMPATIBILITY=1` permits `build`/`build-for-testing` using the pinned Xcode against an explicit iOS 26 destination. It never permits test execution or recording. Install/launch the apps separately; the manual [iOS 26 smoke workflow](../.github/workflows/ios-26-smoke.yml) runs bounded Debug/Release startup checks. Real-device model/UI behavior remains a separate gate.

## Worktree simulator lifecycle

Associate a worktree on first use with [worktree_simulator.py](../Scripts/worktree_simulator.py) `ensure`. It reads the shared Xcode/device/runtime pins and records the simulator UUID, owner path, and Git identity under the common Git directory's `worktree-simulators/registry.json`. This state survives individual worktree deletion. Managed names start with `SuperWT-`; ownership comes from the registry, never a name-prefix guess. Existing unregistered simulators are left alone.

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
