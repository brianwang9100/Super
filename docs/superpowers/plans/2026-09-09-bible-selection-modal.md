# Bible selection modal simplification

## Approach

- Remove the bottom Read action and its dedicated typography/layout from `BibleSelectionSheet`.
- Apply and dismiss immediately when a chapter or verse search result is selected, using the existing bounded `BibleScreenViewModel.applySelection` path. Translation taps update the reader immediately and retain the modal, including its tab/search state. Opening books, typing a search, switching tabs, and closing remain noncommitting actions.
- Rename the sheet's passage completion callback from `onRead` to `onSelect`, add a translation callback to the existing `selectTranslation` method, and update the reader and snapshot fixture. `selectTranslation` will synchronize the sheet's translation without dismissing it.
- Fill the segmented control's base with `theme.backgroundRaised` in a capsule; preserve the selected capsule's `SuperGlass` treatment, animation, and accessibility.
- Apply selected glass directly to the padded label. Native simulator QA reproduced blurred labels when glass was attached to a separate clear background capsule; keeping the label as the glass content fixes the material ordering. Snapshot hosts use a solid fallback, so verify this on the running app.
- Reuse the four existing modal snapshots (light, dark, translation, large text); keep the capture inventory unchanged.

## Risks

Removing the sole commit button must not strand passage/translation choices. Both chapter and verse-result callbacks must commit and dismiss; translation selection must commit without dismissing. The next chapter selection must retain the newly selected translation. Closing must preserve already-applied translations, and browsing must not navigate. Preserve verse bounds, navigation history, persistence, and book-study dismissal handoffs through the existing implementation.

## Validation and delivery

1. Independent plan review before editing implementation.
2. Update translation behavior tests and cover retaining translation across close/reopen and subsequent chapter selection. Run the Bible package suite and the four modal captures on the pinned worktree simulator. Inspect expected visual changes, explicitly record the affected baselines, inspect them, and rerun comparison. Address plan review by interactively checking chapter/verse taps, translation persistence without dismissal, tab changes, browsing, and close on that simulator.
3. Independently review changes and address actionable findings.
4. Create a draft PR with test evidence and unchanged snapshot count; monitor CI and Codex review at the repository's ten-minute cadence. Mark ready and enable auto-merge only after approval and passing checks for the current revision, then verify merge.

## Local evidence

- Independent plan and implementation reviews found no outstanding actionable issues; the material-ordering correction also received a follow-up review.
- Updated behavior tests failed against the old dismissal behavior, then all 952 Bible tests passed after implementation.
- Explicitly recorded and inspected the four intentional modal baseline changes on Xcode 26.4.1 (17E202), iOS 26.4.1 (23E254a), iPhone 17. Capture inventory remains 590 total / 259 Bible / 4 combined-selector images.
- Built and launched SuperBible on the dedicated worktree simulator. Verified chapter 3 opens and dismisses; ASV updates and persists while the translation tab stays open; close preserves ASV; searching and selecting Song of Solomon 5:2-3 opens the passage in ASV and dismisses. Verified both selected tab labels remain legible with native glass.
- Changed-file SwiftLint reports no errors; existing warnings elsewhere in `BibleScreenViewModel` are unchanged.
