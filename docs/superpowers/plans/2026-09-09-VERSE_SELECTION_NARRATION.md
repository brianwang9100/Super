# Verse selection narration

**Goal:** Add a Narrate action immediately to the right of Share in the reader's verse-selection action sheet.

**Approach:** Reuse `BibleScreenViewModel.startNarration()`, which already narrates selected verses in reading order and presents the existing transport sheet. Add an optional `onNarrate` callback to `BibleActionSheet`; render its speaker tile in the third column when available and retain the placeholder otherwise. `BibleStudySheetsModifier` supplies the callback only when it has narration content. Chapter previews deliberately do not own narration lifecycle or transport, so they retain their current actions.

**Scope:** `BibleActionSheet.swift`, `BibleStudySheetsModifier.swift`, the existing action-sheet snapshot fixture, and the affected reviewed PNGs. Keep typography, glass, accessibility labels, selection persistence, playback settings, and the four-column grid consistent with existing controls.

**Risks:** Accidentally starting narration in a preview without transport/lifecycle ownership; losing selection before playback; showing competing native sheets; clipping the new caption. Preserve the shared bottom-sheet routing and existing narration behavior.

## Work

- [x] Review this plan with a subagent and address actionable findings. No findings.
- [x] Add the callback and tile, connect reader narration, and update the existing snapshot fixture.
- [x] Run the complete Bible package suite: 950 tests in 97 suites passed. Existing `startNarrationWithSelectionRestrictsToSortedVerses` covers discontiguous selection, ordering, sheet presentation, and selection preservation; no duplicate logic test is needed for this callback wiring.
- [x] Compare the four existing action-sheet snapshots on the pinned per-worktree simulator, inspect the intended third-column change, explicitly record those baselines, then compare again. All four pass; total inventory remains 590, including 259 Bible images. The simulator run also passed reader view-model and narration lifecycle coverage: 86 tests in three suites. Changed-file SwiftLint and the SuperBible simulator build passed.
- [x] In the running app, select 1 Peter 2:3 and 2:5, tap Narrate, observe verse 3 followed by verse 5 and transport controls, then completed playback with both verses still selected. Code review confirmed previews omit the callback because they provide no narration content.
- [x] Have a separate subagent review the implementation. No actionable findings.
- [ ] Create a draft PR with local results, monitor CI and Codex review every ten minutes, and merge only after current-revision approval and passing required checks.
