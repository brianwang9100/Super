# PR-1: Orphaned `tool_use` Defense-in-Depth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A persisted Chat history must always project to a provider-valid message sequence — every `tool_use` paired with a `tool_result` — no matter how a turn was interrupted (cancel mid-tool, force-quit, crash). Closes audit findings P0-2 and P3-10.

**Architecture:** Three independent layers, innermost first. (1) `ContextAssembler.project` becomes *total*: it synthesizes a `tool_result` for any projected `toolUse` whose result row is missing, and drops any role-`.tool` row whose `toolUse` was never projected — so even already-wedged conversations in users' databases become valid again on their next turn. (2) `ChatSession.executeToolCalls` cancellation-shields a cancelled-status result write for the in-flight tool call *and every not-yet-run call in the same batch* (the same unstructured-`Task` shield the search-proposal path already uses). (3) `ChatSessionStore.recoverInterruptedToolCalls()` — the launch sweep `ToolCallRepository.fetchByStatus`'s doc already promises — resolves rows stuck at non-terminal statuses after a force-quit/crash, called from both app bootstraps before any session exists.

**Tech Stack:** Swift 6 strict concurrency (actors), GRDB in-memory `DatabaseQueue` for tests, swift-testing (`@Test`/`#expect`), existing fixtures `FakeLLMProvider` / `FakeToolExecutor` / `ResumableToolExecutor` (`awaitFirstCall()` seam).

---

### Task 1: Layer 1 — `ContextAssembler.project` totality

**Files:**
- Modify: `Packages/Chat/Sources/Chat/Orchestration/ContextAssembler.swift:359-422` (`project`)
- Test: `Packages/Chat/Tests/ChatTests/Orchestration/ContextAssemblerTests.swift`

- [x] **Step 1: Write two failing tests** (orphaned `toolUse` → synthesized result; orphaned `tool_result` row → dropped), using the suite's existing `makeMessage`/`makeModel` helpers plus a local `makeToolCall` factory. Assert via `assemble(...).messages` (project is private).
- [x] **Step 2: Run to verify both fail** (`swift test --filter ContextAssemblerTests`): the first sees no synthesized role-`.tool` message; the second sees the orphan row projected.
- [x] **Step 3: Implement** in `project`: precompute `resolvedToolCallIDs` (toolCallIds of role-`.tool` rows); track `projectedToolUseIDs` while emitting `toolUse` blocks; after an assistant message with calls, append a synthesized `LLMMessage(role: .tool, content: [.toolResult(toolUseID:, content: interruption notice, isError: true)])` for each unresolved call; in the `.tool` case, `continue` when the row's id was never projected. Doc-comment the invariant.
- [x] **Step 4: Run the suite — green.**
- [x] **Step 5: Commit** `fix(chat): ContextAssembler projects a provider-valid sequence for interrupted tool calls`

### Task 2: Layer 2 — cancellation shield in `executeToolCalls`

**Files:**
- Modify: `Packages/Chat/Sources/Chat/Orchestration/ChatSession.swift:1261-1334` (split into `executeSingleToolCall` + shielded loop; new `cancelUnresolvedToolCalls`), update the now-stale "sub-millisecond / identical exposure" comment at ~744
- Test: `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionToolLoopTests.swift`

- [x] **Step 1: Write the failing test**: script one turn with two `toolUse` calls (`tc-1` backed by `ResumableToolExecutor`, `tc-2` by `FakeToolExecutor`); `send`, `await resumable.awaitFirstCall()`, `session.cancel()`, `waitUntilFinished()`. Assert both `ToolCallRecord`s land `.cancelled` with `completedAt`, both have role-`.tool` result rows, and a follow-up `send` (second script) reaches the provider with a pair-complete history (inspect `FakeLLMProvider`'s captured request).
- [x] **Step 2: Run to verify it fails** — today both records stay `.pending`/`.executing` with no result rows.
- [x] **Step 3: Implement**: per-record `do { checkCancellation; executeSingleToolCall } catch is CancellationError { await Task { cancelUnresolvedToolCalls(records[index...]) }.value; throw }`; `cancelUnresolvedToolCalls` mirrors `resolveProposal`'s persistence shape (status `.cancelled`, encoded `ToolResult`, role-`.tool` row, `.toolCallCompleted` broadcast), `try?`-guarded per step.
- [x] **Step 4: Run the suite — green.**
- [x] **Step 5: Commit** `fix(chat): cancellation-shield tool-result writes for the whole in-flight batch`

### Task 3: Layer 3 — launch recovery sweep

**Files:**
- Modify: `Packages/Chat/Sources/Chat/Orchestration/ChatSessionStore.swift` (new `recoverInterruptedToolCalls()`), `ChatSession.swift:1382` (`encodeJSON(ToolResult)` private → internal), `App-SuperOS/SuperOSAppBootstrap.swift`, `App-SuperBible/SuperBibleAppBootstrap.swift` (call after store construction)
- Test: `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionStoreTests.swift`

- [x] **Step 1: Write the failing test**: seed a conversation + assistant message + five tool calls — `.pending`/`.executing`/`.awaitingConfirmation` without result rows, `.success` with one, `.executing` WITH an existing result row. Sweep → the three orphans land `.failed` + `completedAt` + exactly one new role-`.tool` row each; the `.success` row untouched; the row-bearing `.executing` gets status fixed but **no duplicate** message row.
- [x] **Step 2: Run to verify it fails** (method doesn't exist → compile fail counts; then assertion fail).
- [x] **Step 3: Implement**: fetch the three non-terminal statuses, group by conversation, one `fetchAll` per conversation to detect existing result rows, mark `.failed` with an "interrupted" `ToolResult`, insert the missing role-`.tool` row; best-effort `try?` per record; return recovered ids for logging/tests.
- [x] **Step 4: Wire both bootstraps** to call it right after constructing the store (before any session/UI can stream).
- [x] **Step 5: Run the suite — green.** Build both app targets compile-check the bootstrap wiring (`xcodebuild build` not required for SwiftPM-only check; rely on CI's app-target build legs + local `swift build` for the package).
- [x] **Step 6: Commit** `feat(chat): launch recovery sweep resolves tool calls stranded by a crash/force-quit`

### Task 4: Full verification + PR

- [x] `swift test` in `Packages/Chat` — full suite green (baseline was 1050 tests).
- [x] `swift test` in `Packages/Core` (ContextAssembler consumes Core types; no Core changes expected — sanity only).
- [x] Self-review diff; update `ToolCallRepository.fetchByStatus` doc ("recovery sweep" now true; drop the nonexistent "admin view" claim).
- [x] Review subagent pass; fix must/should findings.
- [x] PR with Test Coverage section; iterate claude-review until APPROVE; enable auto-merge.

## Design notes (read before changing the shape)

- **Why the assembler synthesizes `isError: true` but the shield writes `.cancelled` + non-error text:** the synthesized block exists only for histories written by *older/broken* code paths (or crashes) — flagging it as an error steers the model to acknowledge the gap. The shield's row is a deliberate user action ("cancelled"), mirroring `resolveProposal`'s declined wording, and `project` derives `isError` from `status == .failed` for real rows.
- **Why the shield covers `records[index...]`, not just the in-flight record:** every call in the batch already has its `tool_use` persisted by `streamOneTurn`; cancelling during call *i* would orphan *i+1…n* too.
- **Why the sweep marks `.failed`, not `.cancelled`:** a force-quit isn't a user decision about *that tool*; `.failed` keeps `project`'s `isError` derivation truthful.
- **Why the sweep is on `ChatSessionStore`:** it already owns every repository + clock + idGenerator and is constructed exactly once per launch in both bootstraps; a free-standing type would need the same five dependencies threaded again.
- **Sweep/live-session race:** none — bootstraps call it before the first `session(for:)`; sessions don't exist yet.
