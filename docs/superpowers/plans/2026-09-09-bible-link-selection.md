# Bible link selection implementation plan

**Goal:** Bible links and chapter previews select and scroll to the referenced verses without automatically opening actions; preview selection pills show the reader's disclosure chevron.

**Approach:** Keep the existing selection and native presentation lifetimes. In `BibleScreenViewModel.applyReference`, close actions after assigning the linked selection. In `BibleChapterPreviewViewModel.presentationDidComplete`, only mark readiness; `reopenActions` remains the explicit pill action. Pass `disclosureSystemImage: "chevron.up"` to the preview's existing `SelectionPill`.

**Scope:** Bible package only. No changes to manual verse taps, persistence, deep-link parsing, Core controls, or app composition.

## Steps

- [x] Review this plan with a review subagent and address actionable findings. No serious actionable findings.
- [x] Update reader reference regression coverage for fresh, same-chapter, cross-chapter, queued, and exact-selection handoffs. Assert selection/scroll are retained and actions stay closed, including when actions were already open.
- [x] Update preview readiness and native observer tests to assert closed actions, readiness, selection, and scroll; explicitly request actions in lifecycle tests that need a mounted study sheet. Verify regressions fail before changing production code.
- [x] Apply the three focused production changes above. Confirm explicit pill actions and manual verse selection still open actions.
- [x] Run the full Bible `swift test` suite and relevant simulator suites using the worktree's registered simulator. Update and inspect the three existing chapter-preview PNG baselines for the chevron; capture count stays unchanged. Do not record unrelated baseline differences.
- [x] Obtain a separate change review; address findings and repeat affected validation.
- [ ] Create a draft PR using the repository template, documenting test results and baseline changes. Follow repository CI/Codex review gates through merge; use ten-minute scheduled checks while waiting.

## Risks and validation

- Existing tests assume automatic actions and must set up explicit presentation when testing dismissal; preserve their lifecycle assertions.
- A new link arriving with actions open must close them. Cover same-chapter and chapter-change paths and exact preview-to-reader handoff.
- Initial restoration queues navigation. Verify queued references also remain selected without actions after the real load drain.
- Preview readiness must still guard premature/late actions and repeated native callbacks.
- The chevron changes the pill width. Existing light, dark, and XXL/max-scale preview captures cover that layout risk without adding screenshots.
- If the pinned Xcode/runtime is unavailable, report the exact mismatch and missing simulator verification; do not substitute another renderer's baselines.

## Validation results

- Pre-fix regression run: 26 tests, 14 expected action-presentation issues.
- Post-fix Bible package: 938 tests passed.
- Pinned simulator: 116 tests passed across preview snapshots, native presentation observer, preview lifecycle, reader initialization/history, and reader view-model suites.
- Three inspected preview PNGs updated and comparison rerun passed; Bible inventory remains 255 and total remains 586.
- Plan review and separate implementation review: no serious actionable findings.
- Changed-file lint exits 0 with pre-existing warnings in untouched code; diff whitespace check passes.
