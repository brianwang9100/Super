# Stationary chat responses implementation plan

**Goal:** Sending puts the user's message at the top of the transcript viewport. Streaming text, thinking, tool rounds, completion, cancellation, and errors do not move the reading position. Users scroll freely to read longer replies.

**Scope:** Shared Chat UI and its view-model projection. No provider, persistence, shell, or unrelated applet changes. Existing conversation mounts retain their latest-content positioning. User-authorized refactoring removes the obsolete bottom-follow machinery.

**Approach:**

- Introduce an explicit, equatable scroll request containing the user message ID and a sequence number. The view model emits it after a newly sent user message is projected, or when retry/regenerate starts against an existing user message. Token updates and assistant saves never emit requests. A repeated request can target the same message.
- Pass requests through `ChatScreen.TranscriptObserver`. Group every turn into a stable, user-ID-keyed stack inside a lazy history stack. Apply a viewport-sized minimum height only to the requested turn. This reserves space beneath a short reply without a geometry-to-state measurement feedback loop. Keep this floor after completion and errors; reclaim it on the next explicit turn request. Stable turn containers preserve manually expanded block state when a focused turn becomes history. Normal persisted-history mounts retain their initial position.
- Scroll once to the requested turn ID with a top anchor. Preserve free user scrolling thereafter. Remove token/items-count auto-follow, bottom latches, settle budgets, verbosity bottom snaps, and helper tests that only assert those retired mechanisms. Use a one-shot `ScrollViewReader` seek with bounded materialization refinement; do not retain a `ScrollPosition` target after focus. Keep only an initial bottom anchor and a top anchor for size changes.
- Check actual UIKit scroll geometry before deciding whether a small, geometry-change-only out-of-range correction is still required. It must not follow content growth or interrupt a user's gesture. Preserve the no-blank-viewport regression coverage even if its old mechanism is deleted.
- Keep data contracts and row rendering separate from scroll/layout behavior if extracting them makes `MessageList` easier to maintain. Update Chat design documentation to match the new behavior.
- Publish projected assistant rows and live-tail clearing synchronously after repository reads complete; retain the live tail while reads are suspended. A failed projection keeps a pending user-message scroll target until a successful refresh can display it.
- Keep cancelled/failed partial responses in view-model memory, separately from persisted rows, until another send/retry or reload. Render them without a working spinner, live timer, or persisted-row regeneration action. Preserve readable content as well as offset when interrupted deep in a long reply.

**Risks:** SwiftUI lazy target materialization; first-message mounting; coalesced user-save plus assistant-save updates; transient tail removal before persisted projection; short replies losing their reserve; oversized user messages; resizing and keyboard dismissal; retry/regeneration of the same ID; history remounts resetting expansion state. Validate visible positions, not merely observer decisions. If grouping invalidates stable row identity, prefer an alternative layout that keeps row identity intact.

**Validation and delivery:**

- [x] Independent plan critique addressed: atomic response handoff, interrupted-response retention, stable turn-container identity, and pending target after projection failure.
- [x] Add simulator regressions that fail against current behavior: send from history puts the user at the top; a response grows past the viewport without moving it (including a reader at the response bottom); short completion stays still; manual scrolling survives deltas; successive sends and repeated-target requests work.
- [x] Add view-model tests for request emission on send/retry/regenerate and no emission on response events or failed sends. Use existing strict fakes and drain seams.
- [x] Implement and simplify the scroll path; keep first mount, tiny viewport, resize/keyboard, long user message, thinking/tool/error, and conversation-reset coverage.
- [x] Run full Chat `swift test`, focused UIKit behavioral tests, and affected legacy MessageList/ChatScreen/ChatOverlay snapshots on this worktree's iPhone 17 / iOS 26.4.1 (23E254a) with Xcode 26.4.1.
- [x] Reuse existing visual cases where possible. Add only one focused-turn layout case if needed to show the new reserved space; report before/after capture counts and inspect intentional changes. No unrelated Argos migration.
- [x] Build and manually exercise the app with DebugLLMProvider on the worktree simulator; record evidence and check sustained idle stability.
- [x] Separate code-review subagent; fix findings, rerun affected validation, and create a draft PR using the template.
- [ ] Check CI and Codex review together; monitor every ten minutes while pending. After current-revision approval and passing required checks, mark ready, enable auto-merge, and verify merge, as authorized by AGENTS.md.


## Validation results

- The original behavior reproduced in two new simulator regressions: streamed growth moved the viewport 1,939 points and an assistant save moved it 629 points. Both now pass.
- Full Chat `swift test`: **1,101 tests in 82 suites passed**.
- Full Chat simulator suite: **1,354 tests in 110 suites passed**, including stationary-response, view-model, and all legacy visual comparisons. Xcode 26.4.1 (17E202), iPhone 17, iOS 26.4.1 (23E254a), dedicated simulator `65353303-1E11-4C15-B6C3-2AA7C8C1629A`.
- `Super` simulator app build succeeded. Changed-source SwiftLint and `git diff --check` passed after whitespace cleanup.
- Live Debug (canned) verification: four successive sends placed the user row at y=128–128.33 and kept it there through completion. In Simple mode, opened the observed live thinking header; completed response retained the expanded trace and the same user position. Confirmed idle stability and free manual swiping. Local evidence: `/private/tmp/super-chat-live-expanded.png`.
- One new focused-turn snapshot shows a short answer retaining its viewport reserve. Legacy PNG inventory: **580 → 581 total; Chat 246 → 247**. Updated 14 existing images for inspected glyph/divider subpixel rasterization from stable turn grouping (167–1,692 changed pixels per image); no text reflow or theme changes. Final full comparison passed at the existing precision, with no coverage removals.
- Independent plan review and final implementation review completed. Addressed failed assistant-reload duplication and live-to-saved thinking expansion; added deterministic repository failure/handoff regressions and manually checked expansion persistence. Retired only tests for removed bottom-follow/correction helpers; retained behavior coverage for first mount, oversized messages, resize responsiveness, and readable interrupted replies.

CI and Codex review remain the delivery gates for the pushed revision.
