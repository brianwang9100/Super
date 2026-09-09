# Append-only voice input implementation plan

**Goal:** A pause, empty result, failure, stop, or restarted microphone session must never replace existing composer content.

**Architecture:** Keep the existing injectable `VoiceInputService` and `VoiceInputController` in Chat/Voice. Change recognition output from whole-session replacement snapshots to current-utterance partials plus nonterminal committed utterances. The controller exposes an `AsyncStream` subscription carrying append-only text additions, current provisional preview, and UI state in one ordered update. ChatScreenViewModel subscribes once, appends each addition to its current composerText, and projects the preview separately. No saved composer prefix or final replacement callback remains. The screen displays current composer text plus the provisional preview without writing that display back into the draft.

**Scope:** Architectural refactor of the existing voice/composer seam; no new Swift package, provider, network access, or persistence changes. User has authorized this architecture. Selected UX is finalized phrases appended at pauses with a live provisional preview.

## Risks and invariants

- Interim recognition corrections may revise only the current preview. Empty partial/final callbacks retain the last nonempty hypothesis until committed, preventing a pause from erasing speech.
- Each utterance is emitted exactly once. Repeated identical phrases in separate utterances are legitimate, so do not deduplicate by text.
- The service must yield an utterance before installing the next recognition task and serialize event publication with generation validation. Stale task callbacks must not reorder or replay text.
- Terminal paths flush the pending preview once, including errors, explicit stop, silence timeout, clean stream end, and navigation teardown. Terminal service events fence all later events, including errors and an older stream finishing after restart.
- The controller owns microphone permissions and audio lifecycle; it never sees composer text. Subscription events atomically carry append, preview, and state, so the view model does not display a duplicate or enable send before consuming final text.
- The subscriber task weakly references the view model and is cancelled at deinit. Detach stops capture synchronously and permits the final buffered update to reach the outgoing composer.
- Preserve existing whitespace in the composer; insert a separator only when needed. Append to the current draft, including edits made during the session.

## Work

- [x] Plan review by an independent subagent; incorporate actionable feedback before implementation.
- [x] Add regression tests against the current implementation for empty final dropping a nonempty partial and final callback overwriting a changed draft. Run them and record the expected failures.
- [x] Introduce per-utterance service events and a pure accumulator that retains the current hypothesis and drains one committed phrase. Adapt the production service and its pause/restart event ordering.
- [x] Replace onFinalTranscript with an AsyncStream of voice updates, preserving state/audio ownership and generation guards. Cover stop, errors, repeated phrases, clean completion, cancellation, and stale sessions.
- [x] Subscribe in ChatScreenViewModel, append to current composerText, remove committedComposerText, and keep provisional display separate. Cover multiple pauses, empty callbacks, mid-session edits, restart, whitespace, and detach. Use observable processed-event signals, not sleeps/polling.
- [x] Reuse the existing ChatScreen snapshot suite for the unchanged composer layout; assert committed text plus live preview in view-model regressions. Capture inventory delta is 0 (623 → 623); no baseline changes.
- [x] Run the full Chat swift test suite and relevant simulator tests/captures using the worktree simulator helper. Record exact toolchain mismatch if pinned Xcode 26.4.1 / 17E202 or iOS 26.4.1 / 23E254a is unavailable.
- [x] Independent code review; address serious actionable findings and rerun affected validation.
- [ ] Draft PR using repository template; monitor CI and Codex review every 10 minutes via scheduled wakeup. Only mark ready and enable auto-merge once current revision has explicit Codex approval and passing applicable checks; verify eventual merge.

## Validation examples

1. Draft `typed` + partial `hello` + empty final -> `typed hello`.
2. Draft changes to `edited` while listening + final `hello` -> `edited hello`.
3. Utterance `one` + pause + partial `two` + pause + stop -> `typed one two`, no replay.
4. Committed `yes` followed by another committed `yes` -> `yes yes`.
5. Partial `last words` + recognizer failure -> appended `last words`, failed UI state.
6. Stop and restart followed by stale old final/error -> only the new session may update state or text.

## Plan review resolution

- Subscribe before capture with unbounded buffering; replay only an empty-addition state/preview snapshot. All screen recording state and preview come from the VM subscription. Send is gated until the VM has consumed the terminal update.
- Add explicit synchronous `VoiceInputService.stopRecognition()` so controller stop releases the old capture before marking its audio gate idle. Old termination cleanup acts only on its captured session. Fix the fake to retain distinct session continuations for restart tests.
- Protect watchdog replacement/firing with the session lock and a watchdog generation. Fence terminal callbacks before finishing the stream outside the lock.
- On detach, stop capture synchronously and keep the existing subscription alive while the outgoing VM remains retained. The subscription flushes buffered phrases to that outgoing draft. Deallocating the VM discards that conversation's in-memory draft as it already does; durable draft persistence is outside this change. Tests will retain the outgoing VM and await its processed-update signal.

## Verification results

- Pre-change regressions failed as expected: empty final produced `draft` instead of `draft hello`; final transcript restored `draft hello` instead of preserving `edited draft hello`.
- Review regression `stopDrainsServiceBuffer` failed before the drain fix (`first` instead of `first complete second`) and passed after it.
- Review regression `stopInvalidatesPendingRestart` failed before the start-intent fence (second capture started after stop) and passed after it.
- Full Chat package suite with Xcode 26.4.1 / 17E202: **1,104 tests passed**.
- Pinned worktree iPhone 17 simulator, iOS 26.4.1 / 23E254a: **113 tests passed** across VoiceInputController, DictationTranscriptAccumulator, ChatScreenViewModel, and ChatScreenSnapshot suites. Result bundle: `/tmp/super-voice-final-ios.xcresult` (local only).
- SwiftLint on the 10 changed Swift files: exit 0 (warnings only). `git diff --check`: passed.
- Independent code review: no remaining serious actionable findings after fixing initial-error setup cleanup, buffered stop loss, and stale restart intent.
- Live acoustic recognition was not exercised on physical hardware; deterministic fakes cover phrase ordering, pauses, errors, and session transitions. No layout or capture inventory change.
- After the user-authorized rebase onto the repository snapshot rollback (#354), live main protection retains build, lint, gitleaks, ios-test, swift-test, and native-previews. Argos is retired; default runs compare committed PNG baselines. PR readiness/auto-merge remains gated on CI plus explicit Codex approval of the current head.

## Snapshot rollback integration

- Checkpointed the clean original branch at `codex/append-only-voice-before-snapshot-rollback` and rebased onto `ba1161b1287e31707cf75ca2285f9f282caa1755` without conflicts. `git range-diff` confirms the voice implementation patch is unchanged.
- Preserved all 623 reviewed main-branch PNG baselines and the pinned renderer. Full Chat package rerun: **1,106 tests in 83 suites passed**. Affected simulator suites in comparison mode: **113 tests in 4 suites passed**, including ChatScreen snapshots. No recording or baseline changes. Local logs: `/tmp/super-voice-rebased-tests.log` and `/tmp/super-voice-rebased-ios.log`.
- SwiftLint on the 10 changed Swift files passed with warnings only (`--no-cache` avoids a sandboxed global-cache write); `git diff --check` passed. Independent review found no serious actionable integration issues in the rebased patch.
- Refresh the PR's local evidence, request Codex approval for the new head, and monitor the six required check contexts every 10 minutes. The old-head approval is insufficient after rebasing.
