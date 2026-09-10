# Bible navigation pill implementation plan

**Goal:** Combine Bible history, passage/translation, narration, and chapter actions in one divided glass pill, replacing sparkles with ellipsis and removing the redundant bottom narration button.

**Approach:** Keep the change inside the Bible package. `BibleNavBar` owns the shared glass surface and action segments; `BibleNavigationSelector` supplies history and passage content without a second glass surface. Preserve the existing adaptive layout and independent history/chapter navigation. The standalone selection citation and clear action share the same pill. The shell-hosted reader continues to show its selection controls at the bottom.

## Implementation

- [x] Review this plan with a separate agent and address actionable findings. Include the UIKit narration lifecycle suite, which previously expected a bottom speaker.
- [x] Add focused narration-entry coverage using the existing view-model fixture: idle starts selected verses or the chapter, preparing/speaking/paused reopens controls without restarting, and a visible sheet can be dismissed without stopping playback.
- [x] Rename the spark action API to chapter/menu terminology and remove its narration case. Add a persistent speaker segment before the ellipsis, using the existing controller state and accessible narration citation.
- [x] Move the selector and controls into one shared surface with dividers. Retain 44pt speaker/menu targets and app/OS font scaling. Reserve the shell sidebar button space and allow long names/large text to reflow without clipping. Preserve standalone selection clear/expand behavior.
- [x] Remove `narrationAccessoryButton` and the Bible screen's center accessory publication; retain generic Core/Chat center accessory support.
- [x] Adapt existing navbar geometry assertions and snapshot fixtures; retain capture names and inventory. Existing navigation gallery, compact accessibility, selection, narration, and full-reader snapshots own visual coverage; expected capture count stays 590 (Bible 259).

## Risks and validation

- Compact widths and long book names may force a second row. Verify the normal shell-hosted pill stays compact and inspect the existing narrow accessibility capture for readable reflow, divider placement, and sidebar clearance.
- Narration must not restart when reopening preparing/speaking/paused sessions. Exercise existing fake service and synchronous event seams with selected and whole-chapter text.
- Selection changes the action scope. Keep the ellipsis selection indicator and VoiceOver labels accurate while preserving independent menu access during playback.
- Run `swift test` in `Packages/Bible` with pinned Xcode 26.4.1. Run affected navbar and reader snapshots on this worktree's pinned iPhone 17 simulator. Inspect expected/actual differences before explicit baseline recording, then rerun comparisons and inspect the updated PNGs. Do not alter tolerances or capture inventory to hide failures.
- Adapt and run `BibleScreenNarrationLifecycleTests` on the simulator: center accessory stays absent, chapter/selection accessories remain available, and leaving the reader still stops narration and clears accessories.
- Have a separate agent review the finished diff. Create the repository-template draft PR with test results and screenshots; monitor CI and Codex review together every ten minutes. Only mark ready/enable auto-merge with explicit current-revision Codex approval and passing checks, then verify the merge.


## Validation results

- Plan and implementation reviewed by separate agents. Fixed the compact 375pt long-book row regression identified during review; geometry assertions pass without reducing the 44pt speaker/menu targets.
- `swift test --package-path Packages/Bible`: 953 tests in 97 suites pass with pinned Xcode.
- Pinned iPhone 17 simulator: `BibleNavBarSnapshotTests` (18 tests), `BibleScreenSnapshotTests` (30 tests), and `BibleScreenNarrationLifecycleTests` (2 tests) pass. The two visual suites compare all 48 existing captures after explicit recording; 47 PNGs changed and match the inspected output.
- Capture inventory remains 590 total, including 259 Bible captures. No fixture identities, sizes, or tolerances changed.
- Scoped SwiftLint exits successfully with existing view-model warnings only; `git diff --check` passes.
- PR creation, CI/Codex monitoring, and gated merge follow the delivery workflow.
