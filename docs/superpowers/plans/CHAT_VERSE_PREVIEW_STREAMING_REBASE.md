# Chat verse preview: streamed annotation integration

## Approach

Main `ffbc76d6` adds streamed annotation drafts and shared Core response components
in PR #356. It conflicts with the reader/coordinator extraction in the preview
stack. All current stack heads have Codex approval, but this actual source
conflict requires a reviewed integration and renewed validation. The delivery
heartbeat is paused; all PRs remain draft with auto-merge off.

1. Preserve recovery refs for foundation `ab694815`, preview `d53585ca`, and Chat
   `d88c7398`. Rebase foundation onto `ffbc76d6`, followed by the two dependent
   branches using their exact old parents. Keep the already-corrected unmounted
   child-sheet finish behavior in the preview layer.
2. Move main's request-scoped draft state, progress handling, successful query
   bridge, and guarded cleanup into the existing applet-lifetime
   `BibleAnnotationDispatchViewModel`. Keep `BibleScreenViewModel` draft/progress
   APIs as thin delegates, with independent reader presentation/sidebar state.
   Full readers and temporary previews share one request, cumulative text,
   failure, and completion. Preview disposal must not cancel accepted work.
3. Preserve main's same-target early return before allocating a new request ID;
   reopening a running annotation must neither reset its draft nor consume an ID.
   Keep coordinator-level duplicate protection for every caller. Ignore progress,
   completion, and cleanup from older requests; acknowledge only a matching
   settled draft, preserving a running retry.
4. Adapt `BibleStudySheetsModifier` to main's `draft` and `onClearDraft` inputs.
   Preserve native presentation lifetime callbacks and the preview's inherited
   inert Bible citation policy through `ResponseTextBlock`/`MarkdownText`.
   Keep main's response UI, query acknowledgement, provider completion rules,
   streaming generator, bulk tool-loop path, and dispatcher attachment behavior.
5. Add `bibleAnnotateProgress` to the shell's ignored annotation-event cases while
   preserving its one bus subscription, ordered inbox, and serialized navigation.
   Retain both main's Debug streaming tests and our canned verse-preview fixture.
6. Reconcile inventory documentation with the actual merged inventory: main has
   542 package captures plus 41 native (583); the three approved modal captures
   yield 545 package captures / 586 total. Preserve all main PNGs byte-for-byte,
   including its two new streaming cases. Add no visual capture or tolerance.

## Risks and regression coverage

- Per-reader drafts would lose progress when a preview closes and disagree with
  the shared running request. Use real-bus tests with a full reader and a preview
  made by `makePreviewReader`, checking shared partial text, completed bridge,
  duplicate reopening and continued progress/completion after preview release.
- A delayed query acknowledgement from one reader could erase another reader's
  retry. Exercise matching cleanup across readers and stale cleanup/progress after
  a new request. Retain main's failure/retry/query-authority tests unchanged.
- Re-extracting the annotation sheet could omit its new inputs or citation policy.
  Verify both hosts build, retain native mount/dismissal guards, and manually
  generate/reopen annotations inside the preview with internal citations inert.
- Rebase may silently regress provider protocol or shell order. Audit the entire
  main change set, retain strict provider and generator tests, and verify the
  actual shell event switch together with existing ordered-handoff regressions.

## Validation and delivery

- First run main's dispatch regressions against the integration, then the added
  shared-reader cases; retain a failing-before-fix signal where feasible.
- Run full Core, Bible, and Chat suites with pinned Xcode 26.4.1. Build Super and
  SuperBible. Run the actual-source shell ordering harness with its new event case.
- Run complete default comparison of all 586 images on registered simulator
  `1E3A690B-F069-43F0-974D-7DB5CE1C289F`, including Python capture/retirement/CI
  selection guards and registered UIKit behavior tests. Recording remains off.
- Native QA: modal design/selection, Cancel, Add/New, Open in Bible, and streamed
  annotation generation/reopen/accepted persistence through preview dismissal.
- Obtain an independent implementation review, address findings, and repeat the
  affected validation. Update all PR descriptions and exact-head leases, request
  fresh Codex reviews, then resume the ten-minute CI/review monitor.
- Merge the protected native stack only with current approval and passing
  applicable CI. Verify all three PRs merged before stopping the heartbeat.

## Review and initial verification

Faraday approved the plan after Sagan's independent responsibility audit. The
integrated dispatcher passes all 18 main/shared dispatch tests. With the actual
preview lifetime cases, all 29 targeted tests pass, including success/failure
after preview release and joining the original request. Relevant helpers/tests
pass strict SwiftLint with caching disabled. Main's 583 baseline PNGs and 542
package inventory rows are intact; only the existing three modal captures differ
from main. Full-suite, simulator, native, and independent final review follow.
