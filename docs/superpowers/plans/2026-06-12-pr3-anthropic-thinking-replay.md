# PR-3: Anthropic Thinking Replay in Tool Loops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close audit P0-4 — the native Anthropic adapter cannot complete a tool loop on a thinking model, because the follow-up request rebuilds the assistant turn without its `thinking` block (+ signature), which the Messages API rejects with 400.

**Architecture:** Capture `signature_delta` in the stream reducer, persist it on `MessageRecord` (new `thinkingSignature` column, Chat migration v8), replay the signed thinking block first in the assistant turn via a new `LLMContent.thinking` case, and gate the request-level `thinking` parameter on the history actually being replayable. Follows the Gemini `thoughtSignature` precedent (PR #224 / Chat migration v7), but the signature attaches to the *thinking block*, not the tool call.

**Tech Stack:** Swift 6, swift-testing, GRDB migrations, SSE fixtures, `FakeLLMProvider`.

---

## Ground truth from the Messages API docs (verified 2026-06-12 against platform.claude.com)

1. During tool use, the **last assistant message**'s `thinking` blocks must be passed back **complete and unmodified (including `signature`)**; omitting or rebuilding them → 400 `invalid_request_error` ("`thinking` or `redacted_thinking` blocks in the latest assistant message cannot be modified"). This is exactly our bug: `translate(_:)` rebuilds assistant turns from text + `toolUse` only.
2. Thinking blocks for **earlier** assistant turns are optional (the API filters).
3. `redacted_thinking` blocks must round-trip verbatim — application code that drops them is the documented failure mode. We cannot reconstruct them from our persistence model, so a turn that contained one is **non-replayable**.
4. A request that **disables** thinking against a thinking-bearing history is explicitly tolerated: the API strips incompatible thinking blocks / auto-disables. This makes "thinking off for this request" the safe deterministic fallback for non-replayable histories (legacy rows with no stored signature, redacted turns).
5. On replay, the assistant message that issued `tool_use` must **start** with its thinking block.

## Design

**Signature flow:** reducer → `LLMStreamEvent.thinkingSignature` → `ChatSession` live-turn stash → `MessageRecord.thinkingSignature` (v8) → `ContextAssembler` projects `LLMContent.thinking(content:signature:)` as the assistant turn's **first** block → Anthropic `translate` emits a wire `thinking` block first; all other adapters ignore `.thinking`.

**Redacted thinking:** the reducer tracks whether any `redacted_thinking` block opened during the turn; if so it suppresses the signature emission entirely (emitting at close-out, not per-block, so ordering can't race). No signature persisted → the request gate falls back to thinking-off → the API strips the un-replayable blocks. v1 does not attempt to round-trip redacted payloads.

**Request gate (stage-1 mitigation + stage-2 replay in one rule):** `thinking` is enabled iff the model supports it, the budget fits (existing rule), **and** the history is replayable: the last `.assistant` message either carries no `toolUse` blocks or carries a `.thinking` block with a non-empty signature. Legacy histories (rows persisted before this PR) have no signature → thinking silently off for that follow-up → the loop completes (today it 400s). New histories carry the signature → thinking stays on and the block replays.

**Drive-bys:** P3-1 — a thinking-only turn (no text, no tools, no citations) is currently dropped by the empty-turn guard; include `accumulatedThinking` so it persists. P3-3 — the reducer type doc claims "the caller persists whatever did arrive" on error; `ChatSession.streamOneTurn` actually throws and discards the partial turn — fix the doc.

**Out of scope:** interleaved thinking (multiple thinking blocks per turn — we don't send the beta header; one signature column suffices), redacted-payload round-trip, OpenAI/Gemini reasoning-replay parity.

## File Structure

- Modify: `Packages/Core/Sources/Core/LLM/LLMTypes.swift` — `LLMContent.thinking(content:signature:)`
- Modify: `Packages/Core/Sources/Core/LLM/LLMStreamEvent.swift` — `.thinkingSignature(index:signature:)`
- Modify: `Packages/Chat/Sources/Chat/LLM/AnthropicWireTypes.swift` — `Delta.signature`, `AnthropicContentBlock.thinking`
- Modify: `Packages/Chat/Sources/Chat/LLM/AnthropicStreamReducer.swift` — signature accumulation, redacted tracking, close-out emission, P3-3 doc fix
- Modify: `Packages/Chat/Sources/Chat/LLM/AnthropicNativeLLMProvider.swift` — replay in `translate`, request gate
- Modify: `Packages/Chat/Sources/Chat/Models/MessageRecord.swift` + `Database/ChatDatabase.swift` (v8 migration)
- Modify: `Packages/Chat/Sources/Chat/Orchestration/ChatSession.swift` — signature stash + persist, P3-1 guard
- Modify: `Packages/Chat/Sources/Chat/Orchestration/ContextAssembler.swift` — project thinking block first
- Modify: every exhaustive switch over the two enums the compiler flags (other adapters ignore `.thinking`; `TokenEstimator` counts thinking content; event consumers ignore `.thinkingSignature`)
- Tests: `AnthropicStreamReducerTests` (via provider fixture tests), `AnthropicNativeLLMProviderTests`, `ChatDatabaseTests`/migration, `ContextAssemblerTests`, `ChatSessionTests` (persist + P3-1)

## Tasks (TDD; fail-first where the surface exists)

### Task 1: Core enum cases + compiler sweep
Add `LLMContent.thinking(content: String, signature: String?)` and `LLMStreamEvent.thinkingSignature(index: Int, signature: String)` with doc comments naming the Anthropic replay contract. Build Core, Chat, Bible, Todo; resolve every exhaustive-switch error: other adapters skip `.thinking` in their translate paths (explicitly, with a one-line comment), `TokenEstimator` counts `.thinking` content chars, `ChatSession`/`Compactor`/`TitleGenerator`/Bible consumers ignore `.thinkingSignature`.

### Task 2: Reducer captures signatures (+ redacted suppression, P3-3 doc fix)
- Fixture `anthropic-thinking.txt` already carries `signature_delta` `"abc123"` — write the failing provider-level test first: streaming that fixture must emit `.thinkingSignature(index: 0, signature: "abc123")` before `.messageComplete`.
- Add `Delta.signature`; thinking-block state accumulates signature fragments; track `sawRedactedThinking` on a `redacted_thinking` `content_block_start`; emit one `.thinkingSignature` at close-out iff a non-empty signature accumulated and no redacted block appeared.
- New inline-SSE test: a turn with a `redacted_thinking` block emits **no** `.thinkingSignature`.
- P3-3: correct the type doc ("the caller persists whatever did arrive" → errors surface as `.error` events; `ChatSession` throws and discards the partial turn).

### Task 3: Persistence (v8 migration) + ChatSession stash (P3-1)
- `MessageRecord.thinkingSignature: String?` + `v8_messageThinkingSignature` migration (`ALTER TABLE message ADD COLUMN thinkingSignature TEXT`); migration round-trip test (insert pre-v8 shape, migrate, read back; save/fetch with signature).
- `LiveTurn.thinkingSignature` stash; handle `.thinkingSignature` in `streamOneTurn`'s event switch; persist on the assistant record; reset with the other accumulators.
- P3-1: add `accumulatedThinking.isEmpty` to the empty-turn guard; test: a thinking-only stream persists a row with `thinkingContent` set and empty `content`.
- Integration test: scripted `FakeLLMProvider` stream (thinkingDelta + thinkingSignature + text) → persisted record carries content, thinkingContent, thinkingSignature.

### Task 4: Projection + Anthropic replay + request gate
- `ContextAssembler.project`: assistant rows with `thinkingContent` prepend `.thinking(content:signature:)` as the FIRST block. Test: projection order thinking → text → toolUse.
- `AnthropicContentBlock.thinking(thinking:signature:)` encoding `{"type":"thinking","thinking":…,"signature":…}`; `translate` emits it first for signed `.thinking` blocks on assistant turns (unsigned → skipped). Wire-shape test via `decodeBody`.
- Request gate: `thinkingEnabled` additionally requires the last assistant message in `messages` to be replayable (no `toolUse`, or signed `.thinking`). Tests: (a) history ending in unsigned toolUse assistant turn → `body["thinking"] == nil`; (b) same history with signed thinking → `thinking` present AND the wire assistant content starts with the thinking block; (c) tool-free history → unchanged (existing tests).

### Task 5: Suites, review, PR
`swift test -Xswiftc -warnings-as-errors` in Core, Chat, Bible, Todo. Fable review subagent → fix MUST/SHOULD → PR with Test Coverage section → claude-review loop → auto-merge. Live-API verification (BYOK key + thinking model + real tool round-trip) is required by the roadmap before full trust — if no key is available in-session, flag it on the PR and to the user at the pause point.
