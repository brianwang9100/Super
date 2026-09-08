# OpenAI Narration Prefetch Implementation Plan

**Goal:** Prepare the next two verses by default through a cancellable background queue, reuse downloaded audio, and expose a saved 0–10 verse preference in OpenAI narration settings.

**Architecture:** Keep Bible's existing 100 MiB actor-backed disk cache and speech/player protocols. Replace the single look-ahead task with a session-owned, ordered download queue. Queue bookkeeping is main-actor isolated for synchronous lifecycle cancellation; speech generation and file I/O run asynchronously through Sendable dependencies off the main actor. Only one speculative request runs at a time. Foreground playback joins matching requests and takes priority over pending speculative work.

**Scope:** Bible package only. No new API, library, telemetry, background entitlement, cross-applet dependency, or shell changes. Background means preparation while narration is active, consistent with existing foreground-only playback. Preserve segmentation and credential authorization on cached playback.

## Phase 1 — Design and review

- [x] Inspect current service, cache, persistence, UI, test seams, and lifecycle hooks.
- [x] Independent review subagent critiques this plan; address correctness and coverage findings.

### Queue contract

- Add `NarrationPrefetchQueue.swift` alongside narration services. Requests use the existing cache key: model, instructions, audio format, voice, exact segment text; rate is playback-only.
- Maintain an ordered window containing all remaining segments of the current verse and every segment of up to N subsequent selected utterances. N counts verses, not segments; do not prefetch outside the current selection/chapter.
- Start speculative work only after audible playback starts. N=0 disables all speculation, including current-verse remaining segments. When enabled, complete long current verses before later verses.
- Cache hits skip generation. Retain completed window results until consumed/replaced so cache write failures or admission limits cannot cause duplicate paid requests at handoff.
- Foreground requests reuse in-flight work by key. Skip/restart keeps relevant work and cancels obsolete work; voice changes and new sessions cancel the entire prior queue.
- Pausing prevents pending speculative requests from starting; resume replenishes the window. An already submitted request may finish and cache its result.
- Stop, dismissal, reader exit, chapter/translation replacement, interruption, credential invalidation, clear downloads, and consumer cancellation cancel pending/active work. Late non-cooperative responses cannot play or write cache. Completion cancels any leftover work.
- Prefetch errors remain silent and do not repeatedly retry in the background; foreground demand may retry and owns the existing actionable error UI.

### Persistence and UI contract

- Add `prefetchVerseCount` to `NarrationSettingsRecord`, default 2, and a new SQL migration with NOT NULL DEFAULT 2 and CHECK 0 through 10. Clamp public save/runtime inputs to this range.
- Extend existing credential save paths with optional prefetch count, committed atomically with the same optimistic revision. Existing model-registration callers preserve the saved count. Saving an unchanged connection and count is a no-op.
- OpenAI modal holds a local picker draft, menu style, integers 0…10, defaulting to saved preference. Label: “Verses to prefetch”; explain 0 disables prefetch, additional verses use API credits, and downloaded audio is reused. Dismiss without saving discards draft.
- Configured Apple and OpenAI rows show a green check beside their title and an explicit “Edit...” button opening their existing provider-specific sheet. Unconfigured Set up and pending Checking states remain.

## Phase 2 — Logic and integration

**Files:** `Narration/NarrationPrefetchQueue.swift`, `Narration/OpenAINarrationService.swift`, `Narration/NarrationSettingsController.swift`, `Models/NarrationSettingsRecord.swift`, `Database/BibleDatabase.swift`, `Applet/BibleApplet.swift`, relevant lifecycle/controller files.

- [x] Write failing deterministic tests for default two-verse lookahead before advancing playback, ordered bounded requests, 0/10/clamped limits, full segmented verses, window refill, deduplication, pause/resume, skip/voice/stop cancellation, late-result rejection, and persistent replay.
- [x] Implement queue with injectable speech generator, audio cache, and existing credential closure. Retain existing foreground buffering/error semantics and update deterministic drain seams.
- [x] Add migration/round-trip tests for old records receiving 2, lower/upper bounds, stale drafts, atomic credential/preference saves, and preservation through unrelated settings writes.
- [x] Wire the saved count into production service configuration and apply committed changes safely.
- [x] Cover dismissal/reader lifecycle as resolved with user; retain all other stop hooks.

## Phase 3 — UI and QA

**Files:** `UI/NarrationSettingsPane.swift`, `UI/OpenAINarrationSetupSheet.swift`, existing `OpenAINarrationSnapshotTests`, database schema snapshot if present.

- [x] Implement checkmarks, Edit actions, picker draft and disclosure through existing typography/theme controls.
- [x] Run `swift test` in `Packages/Bible` with Xcode 26.4.1; record results.
- [x] Generate project and ensure this worktree's simulator using `Scripts/worktree_simulator.py ensure`. Match CI Xcode 26.4.1 and runtime 23E254a.
- [x] Record only changed settings/modal captures in existing light/dark/XXL scenarios; inspect images. Expected screenshot inventory delta: 0. Preserve unrelated visual baselines.
- [x] Run Bible simulator tests and relevant lint/diff checks; resolve failures. CI owns full Argos comparison.

## Phase 4 — Delivery

- [x] Separate change-review subagent checks final diff for correctness, cancellation, persistence, concurrency, and regressions; fix findings and rerun affected checks.
- [x] Create draft PR with repository template, phase summary, concrete test results, UI evidence, and before/after screenshot count.
- [x] Request Codex review if absent; record exact requested head SHA. Check CI and review together every 10 minutes through a heartbeat, quiet while unchanged.
- [ ] After explicit Codex approval of current SHA and all applicable CI passes, verify required protections, mark ready, enable auto-merge, and verify merge. Disable auto-merge before any subsequent push; obtain renewed approval and CI afterward.

## Risks and verification

Cancellation must reach every queued task and protect optional cache writes at async boundaries. Use gated generators that deliberately return after cancellation. Paid request deduplication is verified with generated text/voice call counts, including cache failures. Selection bounds and long verses need service-level tests, not just isolated queue tests. Migration is additive and bounded at both API and SQL boundaries. User authorization allows execution of these phases without another plan-approval pause.

Plan review findings incorporated: use a stable stream-session token distinct from restart generation; add cancellation checks at cache actor admission so queued writes cannot repopulate a cleared cache; wire reader disappearance explicitly; test zero with a segmented current verse.

## Execution record

- Baseline: 822 Bible tests passed on Xcode 26.4.1 (17E202).
- New default-whole-verse and migration regressions failed against the old implementation as expected. Updated dismissal expectations also failed before wiring the stop hook.
- Implemented the queue, settings migration and atomic saves, provider checkmarks/Edit actions, and prefetch picker. Existing cached playback still validates the selected credential.
- Full package run: 831 tests passed after updating the schema baseline and historical v10 fixture.
- Local change review identified retention with prefetch disabled; add pruning at every verse boundary and a regression before delivery.
- Worktree simulator: BDE025DE-748A-4123-A604-940AC3EE674E, iOS 26.4.1 build 23E254a.
- Decision: dismissal stops narration and downloads, including replacement of controls with verse actions. Settings editor dismissal retains its existing discard-draft behavior.
- Live main protection requires build, lint, gitleaks, ios-test, swift-test, argos, and native-previews. No protection changes are needed.

Final local logic verification: 832 tests in 82 suites passed. The zero-prefetch retention regression failed before the fix and passes after window pruning at every verse. Scoped review confirmed the fix and explicit visible picker label with no further findings. Existing narration snapshots cover the UI; 24 PNG baselines changed, inventory stays 581→581 (delta 0). No live paid speech requests were used.

Simulator verification with recording disabled: all 1,039 tests in 108 suites passed, including existing UIKit snapshots. Changed-file lint exits 0; only pre-existing BibleScreenViewModel warnings remain.


### PR review and Argos integration

- Opened draft PR #340 and requested Codex review of `16afda78de75a19ef319e12c0fa00a733a694cfd`; a 10-minute heartbeat follows CI and review through verified merge.
- Merged main's completed Argos migration (`30ce9d50`), resolving deleted PNG conflicts by retaining the migrated source fixtures and removing legacy images. Current visual inventory remains **623 → 623** (582 package + 41 native). No generated PNGs are committed in the final PR diff.
- Addressed Codex's cancellation finding by rechecking cancellation after eviction and immediately before atomic file replacement. Rejected writes discard their temporary file and preserve any prior complete clip. Added failing-then-passing regressions for new/replacement clips and real filesystem cleanup.
- Addressed Codex's reader-exit finding by using `dismissNarrationSheet()` on disappearance, clearing presentation state and stopping playback/downloads together. Existing dismissal coverage verifies both effects.
- A separate scoped review found no remaining serious issues in either fix.
- Fresh verification after integrating main: **834 tests / 82 suites** in the full Bible package run and **159 tests / 4 suites** in focused simulator narration, cache, reader lifecycle, and snapshot suites; both succeeded on the pinned environment above.
- Exported all **54 existing narration captures** for local inspection and verified their filenames and pixel dimensions against the Argos inventory. Light/dark/XXL settings and modal layouts are readable. This targeted export is not a complete Argos bundle; CI performs the full comparison.
- The three review-fix Swift files pass SwiftLint with caching disabled. Full changed-file lint retains only pre-existing view-model warnings; diff whitespace checks pass. No live paid speech requests were made.
