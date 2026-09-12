# iPad reader controls revision

## Requested outcome

Restore the previous native verse-action sheet on iPad. Keep the mode icon beside the passage selector and center navigation in every reading mode. Narration remains an inline iPad accessory; iPhone presentation stays unchanged. Auto-merge stays disabled.

## Approach

1. Route selection through the existing native bottom-sheet presenter and retain captured-source actions, dismissal callbacks, and queued handoffs. Only narration uses the inline accessory adapter. Keep Book's stable bottom reservation so presenting either control does not change page breaks.
2. Remove the unused flattened action-sheet rendering. Update the existing regular/large-type control galleries to cover restored actions alongside inline narration without growing the capture inventory.
3. Center the iPad navigation group across the full window (confirmed by the user), using symmetric side clearance and preserving the existing iPhone branch. Export the existing toolbar to a generic owner-keyed shell chrome slot, above both Study panes. Keep the same Chat and reader instances while changing layout; reserve measured toolbar space and avoid drawing controls outside a clipped or competing hit-test region.
4. Resolve CI's confirmed test compile errors: unused Set mutation results in the workspace test double, and a nonisolated test calling a main-actor view helper. Restore the original iPhone narration error-button sizing; the 44-point minimum belongs only to the inline iPad presentation.
5. Update the current draft PR after targeted QA and independent review. Request Codex review on the new revision and monitor CI. Leave draft and merge settings unchanged.
6. Apply the user's reuse requirement: configure the existing chapter reader for comparison rows, sharing its scrolling, chapter header/footer, word selection, decorations, and narration behavior. Keep the comparison component responsible for aligned layout only. Restore Book's marker hit targets, heading/selection accessibility, background dismissal, and suppression of narration paging during selection.

## Review refinements

- Give inline narration a distinct coordinator identity from the native bottom sheet. Outgoing selection callbacks must not unregister incoming narration or close its model flag.
- Restore native-sheet clearance for scrolling Compare/Study while retaining Book's fixed viewport.
- Existing first-selection presentation behavior must remain shared; modes must not unconditionally reopen actions after every verse tap.

## Risks

- Native selection dismissal and inline narration presentation share a coordinator; queued actions must run exactly once after the outgoing presentation completes.
- Navigation must remain visible and tappable in Study and compact windows, with no Chat toolbar collision or remount.
- Native sheet dimensions and iPhone narration error states must match existing baselines. Do not refresh those baselines to accept regressions.

## Validation

- Run Bible package tests with CI's pinned Xcode, parallel execution, coverage, and warnings-as-errors.
- Exercise selection/narration transitions and source-specific handoffs in existing presentation tests.
- Compare Bible action-sheet, narration, OpenAI narration, navigation, reader, and reading-mode UIKit suites. Record only intentional iPad gallery changes and inspect them.
- If shared shell/Core layout changes are needed, run Core/Chat package tests and build both app targets; otherwise build SuperBible.
- Install and spot-check the worktree iPad simulator in Book, Compare, and Study, including action-sheet dismissal and toolbar taps. Verify iPhone layout with unchanged baseline comparisons.

## Completion evidence

Implemented and independently reviewed. Bible (1,006), Core (347), and Chat (1,144) strict package tests passed; both app targets build. The complete Bible UIKit run passed 231 tests and validated all 273 captures. Five reviewed iPad baselines changed with no new captures; existing iPhone baselines are unchanged. iPad checks confirm full-window navigation, correct secondary-source native actions, and retained Chat drafts through mode changes and rotation. The current build was also spot-checked on iPhone. Details and remaining manual input checks are in [the validation record](IPAD_READING_MODES_VALIDATION.md).
