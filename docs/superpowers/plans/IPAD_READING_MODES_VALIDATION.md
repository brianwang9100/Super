# iPad Reading Modes — Validation

Implementation follows [the reading plan](IPAD_READING_MODES.md) and [the controls/reuse revision](IPAD_READER_CONTROLS_REVISION.md). One icon after the passage/translation selector cycles Book → Compare → Study → Book. Only SuperBible on iPad enables the workspace. iPhone and SuperOS keep their existing presentation.

## Automated checks

Pinned local environment: Xcode 26.4.1, iOS 26.4.1, registered worktree iPhone 17 simulator. Package suites used `swift test --parallel --enable-code-coverage -Xswiftc -warnings-as-errors`. Image comparisons ran with recording disabled after five intentional iPad changes were inspected and explicitly recorded.

| Check | Current revision result |
| --- | --- |
| Bible package | 1,006 tests, 105 suites passed |
| Core package | 347 tests, 46 suites passed |
| Chat package | 1,144 tests, 87 suites passed |
| Complete Bible UIKit capture | 231 tests across 30 suites passed; all 273 expected images validated |
| SuperBible and Super simulator builds | Both passed |
| SwiftLint | Passed with existing repository warnings; cache disabled for sandbox compatibility |
| Capture inventory and whitespace | Discovery and `git diff --check` passed |

The capture runner completed all tests before detecting two outdated inventory dimensions for the intentionally resized iPad galleries. Those dimensions were corrected to match the reviewed fixtures. The existing successful run's complete image set was then validated and bundled through the same pipeline validator; no test was skipped or baseline changed to resolve that metadata error.

Regression coverage includes source-specific actions, native-action to inline-narration transitions, once-only queued handoffs, finite pagination and continuation ranges, chapter/book boundaries, bounded cache invalidation, restore/reflow/history, comparison poetry and headings, marker hit targets, shared verse decoration/accessibility behavior, narration-follow suppression during selection, and owner-keyed navigation publication. Chat tests retain interrupted output, draft, model, and scroll state. The prior revision also passed 27 Chat UIKit tests; this controls revision does not change Chat sources.

Independent plan and implementation reviews completed. The final integrated review found no serious actionable issues. Earlier CI compiler failures and nine iPhone narration-error snapshot differences were reproduced and fixed; all 44 OpenAI narration captures now compare against their original baselines.

## Visual coverage

The overall PR changes the inventory from **601 to 609 captures (+8)**: Book continuation in light/dark, compact chapter opening, aligned comparison with missing verses/unequal text/headings/poetry, stacked comparison at 120% app scale, two control galleries including Dynamic Type XXL, and one cycling-icon gallery.

This controls revision adds **zero captures** and updates **five existing iPad images**: centered mode navigation, two comparison layouts using the original reader, and two restored-action/inline-narration galleries. Two inventory dimensions changed to accommodate the full-window navigation and original action-sheet height. Existing iPhone PNG baselines remain unchanged; all existing Bible screen, reader, navigation, action-sheet, and narration captures passed. No tolerances or fixture coverage were relaxed.

The overall PR also refreshes two existing iPad-size BibleScreen baselines for the 44-point navigation-height change already merged in #373. That change had omitted the iPad fixtures added by #372.

## Simulator interaction checks

The current build is installed on both retained worktree simulators. The iPhone spot check shows its original reader typography, local navigation without a mode icon, chapter controls, and minimized Chat overlay.

On iPad, the current controls revision was checked in landscape and portrait. Navigation remains centered across the entire window in Book, Compare, and Study; the same mode callback cycles all three layouts. Compare retains the original chapter title/study glyphs and verse rendering. Selecting a right-column WEB verse opens the restored native sheet with its WEB citation; closing the sheet retains the selection. Clear Selection works from the shell-hosted toolbar. A typed Study draft survives a full mode cycle and rotation, and the Chat header clears the navigation bar.

Earlier integrated checks covered fixed Book page breaks while actions opened, attaching a WEB reference to an existing draft while the primary reader stayed KJV, and a canned response continuing through mode changes. Accessibility inspection exposes mode labels and canonical verse labels on continuation fragments. No real provider requests were needed.

Docked/floating software keyboards, physical-device behavior, and live VoiceOver gesture order remain manual follow-up checks; they are not claimed as verified. Narrow layouts, app font scaling, and large type have automated layout and image coverage.

## Delivery

Update draft PR #374 and request a new Codex review for its new head. Keep auto-merge disabled and the PR draft as requested. The read-only monitor checks CI and current-revision review together every ten minutes; it does not modify code or merge settings.
