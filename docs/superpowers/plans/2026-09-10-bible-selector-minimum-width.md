# Bible selector minimum width

**Goal:** Give short book/chapter labels a stable minimum width based on the average rendered Bible book name, while longer labels can grow and the toolbar remains anchored to the top right.

## Approach

- Measure all 66 canonical book names equally with the selector's existing 15pt medium typography on the pinned iPhone simulator. Add the measured space plus a representative two-digit chapter suffix (` 12`), then retain the existing 8pt horizontal padding on each side.
- Use the rounded-up measured width as the passage content's base minimum. Scale that dimension with OS Dynamic Type and the app font slider, each exactly once. Keep history, narration, and menu widths unchanged.
- Apply the floor to the ordinary horizontal layout. In the existing narrow/large-text fallback, allow the passage to shrink and wrap so the floor cannot cause clipping or obstruct controls.
- Keep the metric local to the selector with a concise derivation comment. Do not add hidden measurement views to production or measure every catalog entry during rendering.

## Work and validation

- [x] Have a review agent critique the approach. No actionable findings.
- [x] Measure the label width using the actual SwiftUI typography and adapt existing selector sizing assertions: short names share the minimum, longer names grow, and both font-scale axes are respected. The old implementation failed the average floor and equal-short-name assertions. Measured mean name width is 59.6212pt; ` 12` is 20pt, giving an 80pt content floor / 96pt padded segment at default size.
- [x] Implement the measured minimum, then rerun the affected Bible package tests and the navbar/reader simulator suites. All 953 package tests and 49 simulator tests pass, including existing long-book compact-width and narrow accessibility checks. Scoped SwiftLint and `git diff --check` pass.
- [x] Inspect expected/actual captures, explicitly record intentional baseline changes, and verify comparison mode. Updated 35 existing baselines (12 navbar and 23 reader); all match the inspected actual captures. Retain all existing capture identities and tolerances; inventory stays 591 total / 259 Bible, with 48 captures in the affected suites.
- [x] Obtain separate implementation review. Corrected the font-scale test fixture to inject the typography environment used in production; the reviewer reports no remaining serious actionable findings.
- [ ] Open a new draft PR with local results and screenshots, request current-revision Codex review, and monitor CI and review every ten minutes. Mark ready and enable auto-merge only after current-head approval and passing checks, then verify merge.

**Risks:** A fixed minimum can overflow accessibility layouts; the fallback must remain unconstrained. Width measurements depend on the renderer and font; use pinned Xcode 26.4.1 / iOS 26.4.1 and the existing typography accessor. Averaging names alone excludes chapter digits, so reserve the chapter suffix separately and document the resulting content/padded widths.
