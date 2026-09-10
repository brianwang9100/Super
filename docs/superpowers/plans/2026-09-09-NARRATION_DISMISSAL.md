# Narration dismissal regression plan

**Goal:** Keep narration playing when the user dismisses narration controls or replaces them with verse actions.

**Cause:** Commit `a1670f0c` added `narration.stop()` to `dismissNarrationSheet()`, which is shared by the close button, interactive dismissal, narration pill, selection actions, and sidebar handoffs.

**Approach:** Restore presentation-only dismissal in `BibleScreenViewModel`. Keep cancellation explicit in `BibleScreen.onDisappear`, and retain existing chapter/translation, background, Stop, and service cancellation behavior. Update the obsolete dismissal comments and expectations. No audio-service or layout redesign.

**Risks:** Removing implicit cancellation must not let playback survive reader exit. Dismissal must preserve preparing/paused sessions and ongoing prefetch, and reopening must not restart playback. Preview dismissal must remain isolated from full-reader narration.

## Implementation and validation

- [x] Have a review subagent critique this plan before implementation. Approved; add native-host regression for leaving the reader with already-hidden controls.
- [x] Update `BibleScreenViewModelTests` to expect dismissal to preserve preparing, speaking, and paused narration; assert controls can reopen without another start or stop. Update the selection-pill regression to preserve narration. Strengthen sidebar handoff coverage to assert continued playback.
- [x] Run focused tests before the fix and confirm the expected cancellation failures. The two affected suites failed with 21 assertions demonstrating cancelled sessions; baseline passed 81 reader tests.
- [x] Remove `narration.stop()` from `dismissNarrationSheet()` and correct its comments. Add explicit `viewModel.narration.stop()` to reader disappearance before dismissing its controls. Audit every dismissal caller for true playback teardown.
- [x] Run all Bible package tests with the pinned Xcode 26 toolchain: 938 tests / 95 suites passed in the normal parallel run. The first run hit an allocator abort; a diagnostic sequential run and normal repeat both passed. Simulator lifecycle/narration, preview isolation, and existing screen/transport/action captures: 230 tests / 10 suites passed on Xcode 26.4.1 (17E202), iOS 26.4.1 (23E254a), iPhone 17. Capture inventory delta 0; no baseline changes.
- [x] Have a separate review subagent review the diff and fix actionable findings. Approved without findings, including the mounted-window lifecycle fixture. SwiftLint passes with existing view-model warnings; `git diff --check` passes.
- [ ] Open a draft PR with test results using the repository template. Monitor CI and Codex review every ten minutes; once the current revision is explicitly approved and all applicable checks pass, mark ready, enable auto-merge without bypassing checks, and verify merge.
