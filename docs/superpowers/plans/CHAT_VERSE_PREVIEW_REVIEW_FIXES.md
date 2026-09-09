# Chat verse preview — review fixes

## Findings and approach

1. PR #349: the UIKit coordinator can reject completion registration while remaining non-nil. Both native readiness observers currently ignore its Boolean return. Capture that result; after rejection, signal readiness from the received `viewDidAppear` while retaining cancellation/dismissal guards and one-shot delivery. Add a UIKit regression using the actual Bible observer under a fake modal container/coordinator; no production testing seam is needed. Apply the same fix to the shell observer in #353.
2. PR #353: routing an ordered batch currently starts independent tasks. Conversation lookup/rebuild and animation suspend, so an older request can commit after a newer one. Add a small, main-actor serial action queue in Core and use it for complete shell transitions, including bootstrap before its first suspension. Queued work waits for its predecessor's completion, not merely actor entry. Keep an idle synchronous fast path for applet/sidebar/settings transitions, preserving their current SwiftUI transaction; enqueue them behind any active asynchronous transition. Keep preview invalidation/arbitration synchronous, reject new previews while navigation is busy, and read Reduce Motion from live reference-backed state so queued actions honor changes made while waiting.

## Regression and validation

- UIKit observer: rejected registration with no callback becomes ready; accepted registration waits; cancellation/dismissal and invalidation do not become ready; a late callback after rejection cannot emit twice. Prove the rejection regression fails on the current code before fixing it.
- Serial queue: suspend an earlier asynchronous action before its state commit, enqueue a synchronous authoritative action, verify it has not run inline, then release and join the work and assert ordered commits/final destination. Verify the idle synchronous path and ordered asynchronous operations. Use existing continuation gates and task joins, with no sleeps/polling.
- Review queue wiring across every `route` case, initial bootstrap, preview acceptance, and deferred navigation after native dismissal. Existing preview completion/destination-reference behavior must remain intact.
- Run complete Core/Bible/Chat package suites as affected, focused UIKit observer tests and existing three preview comparisons, and build both apps on the pinned worktree simulator. Native QA covers preview readiness/actions/Cancel/Open and conversation navigation. No intentional image changes or new captures.

## Delivery and risks

Fix #349 first, retain its current baselines, then rebase #353 onto it with an explicit old-parent boundary. Fix the matching shell observer and navigation lane on #353. Preserve foundation #348, stack #350, user-approved hidden handle/floating pill/title, repository baseline workflow, and renderer pins. All PRs remain draft with auto-merge disabled. Push with a lease for any rewritten branch, reply on each review thread, and obtain current-head Codex approval and passing CI before merging. Avoid cancellation-only fixes, which cannot undo state written before suspension, and avoid serializing only the rebuild while allowing later animation/focus to race.

The CI simulator driver currently selects visual suites plus explicit UIKit behavior suites. Register the new Bible observer suite alongside the existing Chat behavior suite so its regression runs under `ios-test`, and extend the discovery guard to require both. This adds seven behavior tests and zero images. Run the complete 626-image comparison on the final integration revision because the driver selection changes; preserve every baseline and renderer tolerance.
