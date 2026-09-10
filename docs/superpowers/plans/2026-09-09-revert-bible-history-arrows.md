# Revert Bible History Arrows Implementation Plan

**Goal:** Revert PR #360 (`394adcf878e4956443037a9fb0a020c1890ca9b3`) to restore chevron history controls at the user's request.

**Approach:** Reverse only that commit's source patch in `Packages/Bible/Sources/Bible/UI/BibleNavigationSelector.swift`. Restore `chevron.left` / `chevron.right`, the original 32-by-44-point history button frames, and the original spacing comment. Preserve the subsequent combined passage/translation selector and all navigation behavior. Refresh existing affected PNGs on the pinned simulator because PR #361 updated their surrounding layout; old PNGs cannot be restored wholesale.

**Risks:** Overwriting later selector changes; accidentally retaining arrow-specific padding; accessibility glyph clipping or overlap; recording unrelated baseline changes. Inspect the exact reverse source diff and representative default, history-state, narrow accessibility, and integrated reader images. Keep fixture definitions and inventory unchanged.

**Validation:** Run the Bible package's complete `swift test` suite. On Xcode 26.4.1 (`17E202`), iOS 26.4.1 (`23E254a`), and the registered worktree iPhone 17, compare `BibleNavBarSnapshotTests` and `BibleScreenSnapshotTests` serially, inspect intentional failures, explicitly record those suites, inspect PNG differences, and compare again. Existing 48 captures cover the visual risks; add no tests or captures. Run focused SwiftLint and `git diff --check`.

- [x] Review this plan with a review subagent before source edits.
- [x] Create `codex/revert-bible-history-arrows` from current main and reverse the PR's source patch.
- [x] Complete unit, simulator, baseline, lint, and diff validation.
- [x] Obtain an independent change review; resolve actionable findings.
- [ ] Create a draft PR using the repository template, with results and screenshots.
- [ ] Request Codex review for its exact head; monitor CI and review every 10 minutes. After current-revision approval and passing checks, verify required protection, mark ready, enable auto-merge, and verify merge.

## Local results

- Bible `swift test`: 950 tests passed.
- Final pinned simulator comparison: `BibleNavBarSnapshotTests` 18 tests passed; `BibleScreenSnapshotTests` 30 tests passed.
- Updated 37 existing PNGs (13 navigation-bar, 24 reader); affected capture inventory remains 48. The other 11 images remain byte-identical.
- Initial comparison caught the 37 intended differences; inspected glyph changes and large-text layout, explicitly recorded, and verified all 48 baseline images exactly match the inspected RGBA pixels.
- SwiftLint (strict, no cache) and `git diff --check` passed.
- Independent plan and change reviews approved with no serious actionable findings.
