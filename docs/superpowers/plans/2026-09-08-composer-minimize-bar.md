# Chat composer minimize bar

## Goal and accepted design

Ship the simulator prototype accepted by the user on September 8, 2026. Add a 6-point glass capsule beneath the model selector, aligned with its leading edge and the context label's trailing edge. Match the selector's theme-tinted, non-interactive glass treatment; retain the tighter padding approved during prototyping.

## Implementation

1. Give `ChatComposer` an optional `onMinimize` action. Hosts without an action retain their existing layout. Use `superGlassButton(in: Capsule(), interactive: false)` and the existing selection haptic style. The visible bar is 6 points high with 3 points above it; the metadata and bar occupy 28- and 18-point slots, and the capsule bottom padding is 4 points. A 44-point transparent touch region extends into the bottom gutter without covering the model selector.
2. Keep the bar in the existing footer surface so it shares the selector's glass composition. Collapse and fade the entire footer during the composer morph. Disable the bar during partial transitions and remove it from the accessibility tree when minimized. Label it “Minimize chat”.
3. Forward the action through `ChatScreen`, calling its existing `dismissKeyboard()` before asking `ChatOverlay` to animate to `.minimized`. Reset transient drag state and respect Reduce Motion. Preserve text, references, recording, and streaming state.
4. Supply the action in the existing composer preview fixture. Reuse the 21 composer scenarios and nine overlay visual fixtures; add no visual capture cases or retirements. Update the native inventory's intrinsic dimensions and its existing dimension guard for the approved height change. Document the behavior in the Chat UI guide.

## Risks and validation

- Glass composition and alignment: inspect actual simulator rendering and the existing native previews in light/dark, scaled text, editing, and morph states. The bar must use the same material as the model selector, with no custom fill, border, or shadow.
- Touch routing: verify the visible bar and expanded touch region, adjacent model selection and editor focus, and absence of the minimize action in the minimized accessibility tree.
- Presentation/focus: exercise expanded and semi-expanded chat with the software keyboard visible; minimize, reopen, and confirm the draft survives with focus cleared.
- Run Chat's full macOS package suite and the Chat visual capture driver on the registered iPhone 17, Xcode 26.4.1 / 17E202, iOS 26.4.1 / 23E254a. Inspect the affected overlay captures and retain all fixture and behavioral coverage. Compare repository PNG baselines by default; explicitly record, inspect, commit, and recompare intentional changes per `docs/SNAPSHOT_TESTING.md`.
- Capture the full existing 41-image native preview inventory, checking the 21 composer images relevant to this change. Native capture count stays 41→41; package image count stays 582→582 (623 total).
- Build and launch SuperOS in the same simulator. Run SwiftLint on changed Swift files and `git diff --check`.

## Delivery

- Obtain an independent plan review before final implementation cleanup.
- Obtain a separate final code review after QA and address actionable findings.
- Create a draft PR using the repository template, with test results and visual evidence.
- Monitor CI and Codex review together every ten minutes. After explicit Codex approval of the current revision and passing required checks, mark ready, enable auto-merge with protections intact, and verify the merge. Disable auto-merge before any additional push and repeat the gates for the new revision.

## Original implementation verification

- Prototype accepted: final 6-point bar built and shown on the dedicated simulator.
- Integrated main through `95e50574`, including the completed Argos migration; production validation uses its capture drivers.
- Independent plan review: addressed the required Argos migration correction; no other serious actionable gaps.
- Final Chat macOS suite: 1,109 tests in 83 suites passed.
- Chat simulator capture: all 26 selected suites succeeded and the driver validated 244 images, including the nine overlay fixtures and declarative-scroll behavior coverage.
- Native preview discovery/export tests succeeded. The dimension validator identified the intentional layout change: full composer cases grow 8pt (24px), the mid-morph case shrinks 2px, and both minimized cases remain unchanged. Updated inventory metadata/dimensions; all 41 rendered images then passed metadata, dimension, and complete PNG decoding validation. All 22 PreviewPilot guard tests passed, including the updated fractional-height contract.
- SuperOS simulator build succeeded. SwiftLint passed with five pre-existing warnings in unchanged overlay declarations; `git diff --check` passed.
- Inspected light/dark overlay captures and native light/dark, maximum scale plus XXL, reference-pill, morph, and minimized captures. No capture cases added or removed: 623→623 total.
- Manual simulator checks: direct bar tap in semi-expanded chat and lower-gutter tap at y=832 in expanded chat minimize successfully; model selection remains usable; minimized accessibility contains “Open chat” and no “Minimize chat”; a typed draft survives reopening with no caret/focus.
- Live software-keyboard interaction could not be completed because the Mac locked and Simulator's connected hardware keyboard suppresses the software keyboard. The keyboard-visible light/dark layout fixtures passed. An unlock request is pending; this limitation is reported in the PR.
- Independent final source/inventory/test review found no serious actionable issues. Remote CI, repository snapshot comparison, and current-revision Codex approval remain merge gates.

## Repository snapshot rollback integration

Current-revision Codex review identified the initial 36pt touch region as smaller than the documented 44pt minimum. Expand only the transparent label frame to 44pt, retaining the visible bar and footer layout. Simulator verification reports a 340×44pt target in expanded chat and 338.33×44pt in semi-expanded; taps at (80, 846) and (350, 844), respectively, activate the newly added bottom edge and minimize successfully. Minimized accessibility has no minimize action. The full 1,103-test Chat suite, app build, and lint/diff checks pass. Recompare existing native images without recording, then push the fix and request fresh Codex review while keeping design delivery paused.

The fresh 41-image native comparison passes without recording or baseline changes (evidence: `.build/PreviewPilot/run-yh5m2dfi/`). The transparent hit target is the only runtime change in this correction.

PR #354 restored the repository snapshot workflow at `ba1161b1`. Rebase the published implementation onto that revision, preserving the uncommitted design comparisons in a retained recovery stash until published-head validation and the safe-lease push complete. Keep PR #346 draft and auto-merge disabled while the user evaluates the local design. The ten-minute delivery monitor now follows repository PNG comparisons and remains paused. Do not restore Argos uploads or approval requirements.

Record only the inspected composer/overlay baseline differences for this published implementation; retain all 623 capture identities and renderer pins. The initial comparison must fail on the intended differences, and a fresh default comparison must pass after recording. Restore the local design comparison after the maintenance commit, preserving its narrower draggable handle, matching top-handle dimensions, and tighter spacing without including it in this maintenance push.

Published-head validation passes after the rollback: 1,103 Chat tests in 83 suites, all 244 Chat snapshot comparisons, all 41 native preview comparisons, 38 preview guard tests, and the SuperOS simulator build. Explicit recording changed seven overlay and nineteen composer PNGs. Fourteen unrelated native images retain their original baselines and pass the existing rounding policy (96 channel-level pixels total). Inventory remains 623 images. Independent rebase/source/baseline-scope review found no serious actionable issues. Evidence: `.build/rollback-chat-compare/`, `.build/PreviewPilot/run-5qqvqdsd/`, and `/tmp/f585-rollback-chat-tests.log`.
