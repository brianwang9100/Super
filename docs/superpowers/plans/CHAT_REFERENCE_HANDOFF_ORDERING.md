# Preserve ordered Chat reference handoffs

## Finding and approach

Codex finding `3966269494` on PR #353 identifies a lost destination: Add to chat followed by New chat before SwiftUI observes the inbox replaces the first attention request, leaving its reference for the new composer to drain.

Make the shell the sole consumer of complete, ordered reference requests. Each `ComposerAttentionRequest` carries its references for either destination. The inbox queues requests in event order, coalescing only adjacent requests with the same destination intent and deduplicating within that batch. New chat boundaries must remain between current-chat batches. An observable event revision wakes the shell even when a repeated identical request arrives between view updates; the shell synchronously drains all requests into its existing serial navigation queue.

The current-chat handler explicitly adds that request's references to the active view model before its first suspension. The New chat handler passes only its own references into the rebuilt destination. Remove the competing global reference buffer, per-view-model inbox dependency, and ChatScreen mount/change drains. Reference pills remain ordinary view-model state with one explicit deduplicating adoption method. Bootstrap already reserves the navigation queue before subscribing, so requests received during startup execute after the initial composer exists.

The plan review identified a second coalescing point: `RecordPreviewPresentation.deferNavigation` currently retains only the latest navigation. Retain an ordered array of navigation actions through presenting/dismissing instead, append later arrivals, and drain that array into the existing serial queue after native `onDismiss`. Authoritative navigation still cancels the preview's own completion immediately; subsequent bus invalidation must preserve already-deferred navigation, including when it receives a newer authoritative action whose visible transition has not yet been dispatched. Original `openRecord` events are never republished.

## Risks and validation

- First reproduce Add → New before consumption against the current implementation using the real in-memory event bus and its processed-event signal.
- Cover Add → New, New → Add, repeated same-intent batches, alternating Add → New → Add → New, and new events received after consumption while a destination rebuild is gated. Assert exact ordering and reference ownership, including sending from the intended composers. No sleeps or polling.
- Verify presenting and dismissing previews retain the full ordered navigation array, including arrivals after a previous inbox drain. App-only presentation logic follows the documented app-target test exception: inspect the actual state-machine behavior in an isolated local harness and manually verify native dismissal; package tests cover request ordering and complete serial execution.
- Retain reference deduplication, remove-before-send, empty-text reference send, and destination initialization tests. No composer may implicitly drain references on mount or while an earlier transition suspends.
- Run the entire Chat package suite, affected simulator behavior tests and representative Chat reference-pill comparisons, and build both app schemes with the pinned Xcode 26.4.1 worktree simulator. Manually verify modal Add to chat and New chat handoffs. No layout or baseline changes; inventory stays 628.
- Have a subagent review this plan before implementation and a separate implementation review after validation. Address actionable findings and repeat affected checks.

## Delivery

Only PR #353 changes. Keep all three PRs draft and auto-merge disabled, leave foundation #348 and preview #349 at their approved heads, and preserve native stack #350. Reply to the finding with the fix and regression evidence, request a fresh Codex review on the new head, and resume ten-minute joint CI/review monitoring. Merge only after all current heads are approved and applicable checks pass, with live required-check protection enforced.

## Verification

The original Add → New regression failed with two assertions, then passed after the fix. Nine focused tests cover ordered batches and gated composer delivery; the complete Chat suite passes 1,098 tests in 83 suites. The isolated harness using the actual presentation state-machine source fails both initially-presenting and already-presented cases before the fix and passes both afterward. Its app/package boundary types are inert substitutes; native presentation remains covered by simulator QA.

Both Super and SuperBible build on the pinned simulator. Existing ChatScreen and verse-reference pill image comparisons pass with recording disabled, as does the native MessageList behavior suite. No PNG or inventory changes. Changed production files and the inbox tests pass strict lint; the larger existing view-model test file retains the same six pre-existing lint findings outside the changed section.

Native SuperBible QA in Lapis Dark at 120% font scale passes: Add to chat from Romans 8:28–30 dismisses both sheets and attaches one Romans reference to the existing Verse preview conversation. A subsequent John 3:16–17 preview → New chat creates a new composer containing only the John reference. The Bible backdrop remains Romans 8 KJV, and the modal retains its selected-verse title and hidden outer handle. Independent implementation review approved with no actionable findings.
