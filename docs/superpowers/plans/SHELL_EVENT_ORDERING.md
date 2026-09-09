# Preserve shell event order across reference delivery and navigation

## Finding and approach

Codex finding `3971418471` identifies two independent scheduling paths: Chat reference events use `ChatReferenceInbox` and one SwiftUI observer, while conversation navigation uses the shell bus subscriber and another observer. A later conversation switch can run before an earlier Add to chat handoff.

Use one shell bus subscription and one ordered inbox for every shell request. Handle `recordAddedToChat` in the existing shell event loop, carrying the complete reference request into the same queue as conversation changes and previews. Remove the obsolete Chat inbox and its subscription/test seam; retain `ComposerAttentionRequest` as a value type. Introduce a small main-actor `OrderedInbox<Element>` in Core for explicit enqueue/drain/filter and an observable revision, so repeated identical requests cannot disappear between SwiftUI updates. Keep shell-specific request classification in the shell.

Follow the plan review's recommendation to preserve one request per event. The inbox does not coalesce events: every explicit New chat event remains a conversation boundary. Reference deduplication stays in the destination view model; this removes the prior batch-merging policy and avoids merging across any navigation boundary.

Plan review also identified direct UI navigation overtaking received bus work. Separate ingress from dispatch: direct `route` calls append their own navigation after pending requests and synchronously drain the queue using the fresh view/environment, preserving the idle synchronous transaction. The revision observer only drains. Dispatch sends complete navigation through the existing `SerialActionQueue`, with current-chat attachment before suspension and New chat references reserved for its destination.

Outer dismissal dispatches its already-ordered deferred actions before draining later inbox requests; it must not re-enqueue deferred actions behind newer work. Preserve immediate invalidation of stale preview completions, ordered deferred arrays, bootstrap's initial serial-queue reservation, live Reduce Motion, and original `openRecord` delivery without replay.

## Validation and scope

- Reproduce Add followed by open-existing or New conversation under a gated dual-subscriber host using the real event bus; show wrong ownership on the old scheduling shape, then test the single subscriber/inbox path with the same destination assertions. Also test reverse ordering and events received during a gated rebuild/startup.
- Unit-test inbox FIFO order, revision changes for identical events, drain ownership and filtering. Assert identical New chat events remain separate boundaries.
- Adapt Chat reference ownership/send tests to the unified event stream. Run full Core and Chat suites; Bible code and all baselines stay unchanged.
- Inspect actual app dispatch logic with the local source harness and separate review, including direct UI navigation before observer drain, arrivals during native dismissal, and no replay/double dispatch. Native app wiring follows the documented app-target exception.
- Build both apps on the pinned simulator; repeat representative Chat comparisons and native Add/New/navigation handoffs. No image recording, inventory changes, or design changes.
- Have the plan reviewed before implementation and a separate agent review the final changes. Address actionable findings before pushing.

## Delivery

Only PR #353 changes. Keep #348 and #349 at their approved heads, all PRs draft, auto-merge off, and the native stack intact. Update the PR evidence, reply to the finding, request current-head Codex review, and resume ten-minute joint monitoring. Merge the stack atomically only after approval and applicable CI pass with required protection enforced.

## Verification

The gated dual-subscriber reproduction failed four ownership assertions for Add → open-existing and Add → New before the fix. The unified host passes both orders for both navigation kinds, startup/direct-UI delivery and a reference arriving during a gated rebuild. The complete Core suite passes 335 tests in 43 suites; Chat passes 1,094 tests in 82 suites. The removed inbox's tests are replaced by five generic inbox tests and expanded mixed-event ownership tests; obsolete adjacent-coalescing behavior is intentionally removed.

An isolated local harness extracts the actual shell ingress, drain, dispatch, event switch, reference handler and native dismissal state machine. All 17 assertions pass: bus/direct UI ordering, earlier deferred actions before newer undrained work in both presentation phases, stale completion suppression, no replay/double dispatch and the idle synchronous path. App service/view boundary types are inert substitutes, and explicit captures accommodate the harness's class wrapper; full app builds and native QA remain the verification for real SwiftUI wiring.

Both Super and SuperBible build with the pinned toolchain. New helpers and tests pass strict lint; unrelated existing test-file and AppShell lint findings remain. No baseline or inventory changes. Separate plan and implementation reviews approved with no remaining actionable findings.

The pinned simulator passes all 13 ChatScreen comparisons, five reference-pill comparisons and 12 MessageList UIKit behavior tests with recording disabled. Native SuperBible Lapis Dark/120% verifies direct sidebar conversation opening, then Romans 8:28–30 Add to chat attaching exactly once to that existing conversation, followed by John 3:16–17 New chat creating a new composer with John only. Both nested sheets dismiss fully and the Bible backdrop remains Romans 8 KJV. The task-owned accessibility companion was stopped after QA.
