# Narration Reopen Button Implementation Plan

**Goal:** Show a sound icon between the reader's bottom chapter arrows while narration is active and its sheet is dismissed. Center it when alone; place it immediately left of the verse-selection pill when present. Tapping opens the narration sheet without restarting playback.

**Approach:** Extend Core's existing `ComposerAccessoryButtons` descriptor with an optional center button. Chat renders the center button and selection together with an 8-point gap. Bible supplies the sound icon through its existing accessory publication, observing narration state and sheet presentation. Keep the existing top-bar control and standalone reader behavior.

**Constraints:** Applets only import Core. Use `SuperTypography`, `SuperGlass`, 44-point button targets, accessible names, and existing motion policy. Work only in `/Users/bwang/.codex/worktrees/2f29/Super`.

## Implementation and validation

- [x] Have a review subagent critique this plan before implementation.
- [x] Add optional `center: ComposerAccessoryButton? = nil` to `ComposerAccessoryButtons` and include it in `isEmpty`. Add a Core regression for a row with only a center control.
- [x] Render a centered `HStack(spacing: 8)` containing the optional button followed by the existing selection pill in `ComposerAccessoryFlank`. Footer visibility continues to hide only edge arrows.
- [x] Add an internal computed narration accessory on `BibleScreenViewModel`: return nil for idle or an open narration sheet; otherwise return `speaker.wave.2.fill`, an accessible open-narration label, current navigation-enabled state, and an action calling `presentNarrationSheet()`.
- [x] Publish this center descriptor in `BibleScreen`, refreshing on narration state and narration sheet presentation changes. Preserve selection publication and lifecycle cleanup.
- [x] Add behavior coverage for idle/preparing/speaking/paused visibility, reopening without restarting playback, and actual hosted-reader accessory refresh after dismissal/stopping.
- [x] Add one compact gallery capture covering sound alone, sound plus selection, hidden arrows, and a long selection at maximum app font scale. Existing light/dark selection captures retain shared glass contrast coverage. Register the new capture; inventory grows by one.
- [x] Run `swift test` in Core, Bible, and Chat. Run affected UIKit behavior and accessory snapshot suites on the worktree simulator using pinned Xcode 26.4.1 / 17E202 and iOS 26.4.1 / 23E254a. Inspect and explicitly record only the intentional new baseline, then compare again.
- [x] Have a separate review subagent review the changes; address actionable findings and repeat affected QA.
- [ ] Open a draft PR with the repository template, test results, screenshot count change, and visual evidence. Monitor CI/Codex review every 10 minutes. Only after current-revision Codex approval and passing applicable CI, mark ready, enable auto-merge with required checks enforced, and verify the merge.

## Risks

- A static accessory descriptor can become stale after dismissal or playback transitions; hosted-reader publication coverage must exercise both.
- A long selected citation can crowd the new button; keep both 44-point targets and verify truncation and chapter arrows in the gallery.
- Footer visibility must not hide the only route to dismissed narration controls.
- If the exact pinned renderer is unavailable, report missing simulator coverage rather than accepting different-renderer PNGs.

## Review and QA results

- Plan review: no blocking findings; added a reader-disappearance assertion ensuring accessory cleanup is preserved.
- Change review: no actionable correctness findings.
- Core regression failed with a center-only row considered empty, then passed after the `isEmpty` fix.
- Full local package suites: Core 339, Bible 950, Chat 1,144 tests passed.
- Existing accessory snapshots compare unchanged; new gallery initially fails only because its baseline is absent, as expected.
- Pinned simulator verification: accessory suite passed (11 tests / 15 captures); Bible narration lifecycle and view-model suites passed (83 tests). New gallery inspected and recorded explicitly, followed by a successful comparison.
- Capture inventory: 590 → 591 total images, with one gallery for the new center-button placement and crowded selection risk; existing captures retained unchanged.
- SwiftLint: no violations in the new/changed control and test code; pre-existing warnings remain elsewhere in `BibleScreenViewModel`. Inventory discovery and `git diff --check` passed.
