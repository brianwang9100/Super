# Super Chat MVP — Implementation Status

**If you are an AI session or engineer resuming this work: read this file first.** It is the single source of truth for *where we are*. The plan is the source of truth for *what we are doing*.

## Quick links

- **Plan**: `/Users/bwang/.claude/plans/zany-dazzling-willow.md` — the full approved implementation plan (all 13 milestones M0–M12).
- **Project agent rules**: `/Users/bwang/Development/Super/AGENTS.md`. `CLAUDE.md` is a symlink to it.
- **Design reference (canonical visual)**: `/Users/bwang/Development/Super/.design-tmp/chat/project/`
  - `Super.html` — entry point.
  - `src/theme.jsx` — palette tokens (oklch) for Light / Dark / Sepia.
  - `src/chat-view.jsx` — chat screen, composer, header, pills.
  - `src/sidebar.jsx` — drawer.
  - `src/settings.jsx` — settings sheet + panes.
  - `src/message-parts.jsx` — block renderers (text / thinking / tool / code).
  - `src/data.jsx` — seed data (also useful as test fixtures).
  - `chats/chat1.md` — the user/designer chat log that established verbosity semantics, composer shape, etc.
- **Architecture docs** (under `docs/`): `PRODUCT_VISION.md`, `MOBILE_ARCHITECTURE.md`, `Chat/ARCHITECTURE.md`, `CLIENT_SERVER.md`, `SYNC.md`, `AUTH.md`, `CI_PIPELINE.md`, `SECURITY.md`, `OBSERVABILITY.md`, `AI_TOOLS.md`, `DEVELOPMENT_SETUP.md`.

## Current state

- **Active milestone**: M6 — Tool system + built-in tool (next up)
- **Last action**: M5 done (incl. review fixes) — `TokenEstimator`, `ContextAssembler`, `Compactor`, and `SlashCommand` landed under `Packages/Chat/Sources/Chat/Orchestration/`. `ChatSession` now folds in compaction: each turn calls `ContextAssembler` (which projects messages + live `CompactionCheckpointRecord` into `[LLMMessage]` and reports `ratio`/`isOverThreshold`); when `autoCompactEnabled` and over `autoCompactThreshold` (default 0.75) the pre-flight calls `Compactor.wouldCompact(...)` (pure predicate sharing `messagesToSummarize` slicing with `compact(...)` so the two paths cannot disagree), then runs `Compactor`, emits `.compactionStarted` / `.compactionCompleted(CompactionCheckpointRecord)` `ChatEvent`s, persists the new live checkpoint (atomic with prior-live demotion in one write), then re-assembles before driving the actual turn. `ChatSession.send(text:model:)` recognizes `/compact` via the `SlashCommand` parser and dispatches to a public `compact(model:)` method instead of writing a user `MessageRecord`. The compactor summarizes everything except the last 4 messages (`Compactor.defaultKeepMostRecent`); shorter histories no-op and skip both the LLM call and the `.compactionStarted` event so the UI doesn't flash an empty banner. `ContextAssembler` always re-emits any leading `.system` rows that the checkpoint window covers (in front of the synthetic summary) so a future system-prompt `MessageRecord` won't get summarized away. `ChatSessionStore` threads `checkpointRepository` + `Compactor` + `autoCompactEnabled` + `autoCompactThreshold` through to every session. **153 Chat tests across 21 suites pass** (122 M4-era + 6 `TokenEstimator` + 8 `ContextAssembler` + 8 `Compactor` + 5 `ChatSession compaction` + 4 `SlashCommand`). Core stays green (70 tests). `xcodebuild -scheme Super build` for iPhone 17 sim still succeeds. `ChatLiveLLM` smoke script updated to wire the new dependencies and renders compaction events.
- **Repo root**: `/Users/bwang/Development/Super/`
- **Next concrete sub-step (M6)**: implement `TimeNowTool` (only real tool in MVP) under `Packages/Chat/Sources/Chat/Tools/`, register it in `SuperApp` (the iOS app target's composition root). Add `TimeNowToolTests` (FixedClock → deterministic output). `RemoteHTTPToolExecutor` is already implemented + tested in Core (M1) but no remote `ToolRegistration` ships in v1.

## Session-resume procedure

1. Read the **Current state** block above.
2. Skim the **Milestone status** table below to see the whole picture.
3. Jump to the in-progress milestone's detail section further down for the latest specific notes (file paths touched, pending sub-steps).
4. Pull the corresponding milestone block out of the plan file for full requirements.
5. Resume.

Do not re-litigate scope. The plan is approved. If something in the plan looks wrong, flag it to the user before changing course — don't silently deviate.

## Milestone status

| # | Title | Status | Updated |
| --- | --- | --- | --- |
| M0 | Project scaffolding | `[x] done` | 2026-04-24 |
| M1 | Core primitives | `[x] done` | 2026-04-24 |
| M2 | Chat persistence | `[x] done` | 2026-04-24 |
| M3 | OpenAI-compatible streaming | `[x] done` | 2026-04-25 |
| M4 | Session orchestration | `[x] done` | 2026-04-25 |
| M5 | Compaction | `[x] done` | 2026-04-25 |
| M6 | Tool system + built-in tool | `[ ] not_started` | — |
| M7 | Chat UI | `[ ] not_started` | — |
| M8 | Sidebar drawer | `[ ] not_started` | — |
| M9 | Settings | `[ ] not_started` | — |
| M10 | Markdown + code + thinking rendering | `[ ] not_started` | — |
| M11 | Voice input | `[ ] not_started` | — |
| M12 | End-to-end polish + coverage | `[ ] not_started` | — |

Legend: `[ ]` not started · `[~]` in progress · `[!]` blocked · `[x]` done.

## Update discipline

- **Starting a milestone**: flip its checkbox to `[~]`, set `Status:` to `in_progress`, stamp `Last updated:` to today (absolute date), write a one-line `Notes:` about the first concrete sub-step.
- **Pausing mid-milestone**: update `Notes:` with the latest file touched and the exact next sub-step. Enough detail that a cold reader can resume in under 5 minutes.
- **Finishing a milestone**: flip to `[x]`, set `Status:` to `done`, summarize what landed + where the tests live, update the `Current state` block at the top to point at the next milestone.
- Commit this file in the same PR as the milestone work it describes — never as a standalone "status update" commit.

---

## M0 — Project scaffolding

- **Checkbox**: `[x]` done
- **Status**: `done`
- **Last updated**: 2026-04-24
- **Notes**:
  - Skipped the plan's SuperBig→Super rename per user direction; repo lives at `/Users/bwang/Development/Super/`.
  - `git init -b main` + `.gitignore` (excludes `.design-tmp/`, `.DS_Store`, SPM build artifacts, Xcode user state).
  - `Packages/Core/` (Swift 6, iOS 18+, no deps) — `Sources/Core/Core.swift` + 1 placeholder test, `AGENTS.md` + `CLAUDE.md` symlink.
  - `Packages/Chat/` (Swift 6, iOS 18+, deps: `GRDB.swift` 7.10.0, `GRDBQuery` 0.11.0, `swift-markdown-ui` 2.4.1, `Splash` 0.16.0; test deps: `swift-snapshot-testing` 1.19.2, `GRDBSnapshotTesting` 0.4.2; local `Core` dep) — `Sources/Chat/Chat.swift` + 2 placeholder tests, `AGENTS.md` + `CLAUDE.md` symlink.
  - `xcodegen` (2.45.4) installed via Homebrew; `project.yml` describes the iOS 18+ `Super` app target linked to both local packages; `xcodegen generate` produces `Super.xcodeproj`.
  - `App/{SuperApp.swift, ContentView.swift, Info.plist, Assets.xcassets/}` placeholders. ContentView prints the wordmark, "Chat MVP scaffolding", and `Core v… · Chat v…`.
  - `.mcp.json` wires `xcodebuildmcp` + `ios-simulator-mcp` (the latter replaces the plan's placeholder "Axiom MCP" — verified npm package). `.claude/settings.json` (project-shared, checked in — note: the plan said `.local.json` but the local-suffixed file is conventionally per-developer and globally git-ignored, so the shared settings live in `settings.json`) allowlists those MCP tools and a small set of safe Bash commands (`swift test`, `xcodebuild`, `xcrun simctl`, `git status/diff/log/add/commit`).
  - `docs/DEVELOPMENT_SETUP.md` §8.5 added to document the MCP tooling story (what each server does, smoke checks, fallback to plain bash).
  - Verifications: `swift test` green in both packages; `xcodebuild -scheme Super -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build` succeeded; app installed and launched in the iPhone 17 simulator (PID confirmed); screenshot shows the placeholder wordmark.
  - Files added in this milestone (high level): `.gitignore`, `.mcp.json`, `.claude/settings.local.json`, `project.yml`, `Super.xcodeproj/`, `App/{SuperApp.swift, ContentView.swift, Info.plist, Assets.xcassets/*}`, `Packages/Core/{Package.swift, Sources/Core/Core.swift, Tests/CoreTests/CoreTests.swift, AGENTS.md, CLAUDE.md}`, `Packages/Chat/{Package.swift, Sources/Chat/Chat.swift, Tests/ChatTests/ChatTests.swift, AGENTS.md, CLAUDE.md}`, `docs/DEVELOPMENT_SETUP.md` (edited).

## M1 — Core primitives

- **Checkbox**: `[x]` done
- **Status**: `done`
- **Last updated**: 2026-04-24
- **Notes**:
  - Full Core surface landed under `Packages/Core/Sources/Core/`:
    - `LLM/`: `LLMTypes.swift` (`LLMRole`, `LLMContent`, `LLMMessage`, `LLMModel`, `ModelConfiguration`, `TokenUsage`, `LLMError`), `LLMStreamEvent.swift` (with `.thinkingDelta` — divergence from `MOBILE_ARCHITECTURE.md` §7 to be reconciled in M12), `LLMProvider.swift`, `LLMProviderRegistry.swift` (actor; first-registered-becomes-active).
    - `HTTP/`: `HTTPClient.swift` (protocol + `URLSessionHTTPClient` using `URLSessionDataDelegate` + `HTTPError`), `SSEParser.swift` (buffered, partial-chunk-tolerant; supports both LF and CRLF separators; recognizes `[DONE]`).
    - `Tools/`: `LLMTool.swift` (+ `LLMToolCategory`, `LLMToolParameter`, `ParameterType`), `ToolExecutor.swift` (+ `ToolResult` + `Artifact`), `ToolRegistration.swift` (+ `ToolExecution` enum), `RemoteHTTPToolExecutor.swift` (+ `RemoteToolEndpoint`; scaffolded — registry throws `remoteExecutionNotConfigured` for `.remote` per the plan), `ToolRegistry.swift` (actor; persists via `ToolEnablementStore`).
    - `Ambient/`: `Clock.swift` (`SystemClock` + `FixedClock` using `OSAllocatedUnfairLock`), `IDGenerator.swift` (`UUIDGenerator` + `DeterministicIDGenerator`), `KeychainClient.swift` (`AppleKeychainClient` via Security framework + `InMemoryKeychainClient` shipped in Core for previews/tests), `SuperAppInfo.swift`.
    - `JSON/JSONValue.swift`: Sendable JSON value tree replacing Foundation's non-Sendable `[String: Any]` for tool I/O.
    - `ChatVerbosity` moved to `Packages/Chat/Sources/Chat/ChatVerbosity.swift` — `simple`/`thinking`/`verbose` enum with `atLeast(_:)` ordering, consumed only by Chat's settings pane, system-prompt builder, and view models.
  - Tests landed under `Packages/Core/Tests/CoreTests/` mirroring the source layout: `SSEParserTests` (13 cases — chunk boundaries, CRLF, `[DONE]`, comments, multi-data lines, finish-flush), `URLSessionHTTPClientTests` (5 cases via per-stub-id `URLProtocolStub` so concurrent suites don't trample each other), `LLMProviderRegistryTests` (10 cases — register/unregister/setActive/swap), `ToolRegistryTests` (10 cases — register/enable/disable/lookup/execute, plus enablement-store hydration + persistence), `RemoteHTTPToolExecutorTests` (4), `JSONValueTests` (4), `ClockTests` (4), `IDGeneratorTests` (3), `KeychainClientTests` (5), `SuperAppInfoTests` (2), `LLMToolTests` (4), `ToolRegistrationTests` (3). `ChatVerbosityTests` (4) moved to `Packages/Chat/Tests/ChatTests/`. Total: **73 tests across 13 suites, all green**.
  - `xcodebuild -scheme Super -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build` succeeds — the M0 app target still builds against the expanded Core.
  - Documentation: every public declaration in Core has a `///` doc comment placed directly above it. Multi-parameter or non-obvious functions (`HTTPClient.stream`, `LLMProvider.stream`, `SSEParser.append`/`finish`, `ToolRegistry.execute`/`register`, `RemoteHTTPToolExecutor.execute`) carry `- Parameters:` / `- Returns:` / `- Throws:` markup. Test suites and helpers are documented at the type level. Root `AGENTS.md` gained two new sections: **Source-file documentation** (`///` next to declarations, expand acronyms on first use) and **Swift function declarations** (argument labels, defaults at end, implicit returns, `inout` rules, throws conventions — sourced from `https://docs.swift.org/swift-book/documentation/the-swift-programming-language/functions/`).

## M2 — Chat persistence

- **Checkbox**: `[x]` done
- **Status**: `done`
- **Last updated**: 2026-04-24
- **Notes**:
  - Source under `Packages/Chat/Sources/Chat/`:
    - `Models/`: `ConversationRecord`, `MessageRecord` (with Chat-owned `MessageRole` enum: `user`/`assistant`/`system`/`tool`, identical case set to Core's `LLMRole` today but a deliberate type boundary so a future provider case or Chat-only row kind becomes an explicit decision in the translation extension rather than silent schema drift), `MessageRole` + `asLLMRole()` / `init(_ llmRole:)` (separate file), `ToolCallRecord` + `ToolCallStatus` enum (`pending`/`executing`/`success`/`failed`/`cancelled`/`awaitingConfirmation`) + `JSONValue` codec helpers (`decodedParameters()`, `decodedResult()`, `static encode(_:)`), `ModelConfigurationRecord` (with `.configuration` projection to Core's `ModelConfiguration`), `ToolEnablementRecord`, `SettingRecord`, `CompactionCheckpointRecord`. All `Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable`.
    - `Database/ChatDatabase.swift`: `DatabaseQueue` wrapper with `.open(in:)` (on-disk under `chat.sqlite`) and `.makeInMemory()` (tests). Public `registerChatMigrations(_:)` ships `v1_createTables` covering all 7 tables + indexes (`conversation_on_updatedAt`, `message_on_conversationId_createdAt`, `toolCall_on_{conversationId, messageId, status}`, `compactionCheckpoint_on_conversationId_isLive`, plus the partial unique `modelConfiguration_unique_selected` index that makes the "at most one selected row" invariant a schema law). Cascades: deleting a `conversation` cascades to `message` and `compactionCheckpoint`; deleting a `message` cascades to `toolCall`.
    - `Repositories/`: protocol-typed surface (`ConversationRepository`, `MessageRepository`, `ToolCallRepository`, `ModelConfigurationRepository`, `SettingRepository`, `CompactionCheckpointRepository`) with GRDB conformers, plus `GRDBToolEnablementStore` conforming to Core's `ToolEnablementStore` (so Chat owns persistence while Core stays GRDB-free). `ModelConfigurationRepository` owns the Keychain pairing for API keys via injected `KeychainClient`; `delete(id:)` removes the Keychain entry **first** so a Keychain failure leaves the row in place to retry instead of orphaning a secret no UI handle can reach. `MessageRepository` has no per-message delete by design (documented on the protocol). Live-exclusive invariant on `compactionCheckpoint` enforced inside its write transaction; selected-exclusive invariant on `modelConfiguration` is enforced by the schema-level partial unique index.
    - Column casing unified on `Id` (lowercase d): `modelId` and `toolId` joined the existing `messageId`/`conversationId`/`toolCallId` for in-package consistency.
  - Tests under `Packages/Chat/Tests/ChatTests/`:
    - `Database/ChatDatabaseMigrationTests` (7 cases — table set, index inventory, `message` column shape, FK cascade, idempotency, partial unique index, plus a `GRDBSnapshotTesting` `dumpContent` snapshot of the full v1 schema).
    - `Models/ToolCallRecordTests` (4 — encode/decode round-trip, nil-result for pending row, invalid-JSON throw).
    - `Models/MessageRoleTests` (5 — raw values, `asLLMRole()`, `init(_ llmRole:)`, round-trip totality, allCases exhaustive).
    - `Repositories/ConversationRepositoryTests` (5), `MessageRepositoryTests` (5), `ToolCallRepositoryTests` (6 — incl. cascade-from-message), `ModelConfigurationRepositoryTests` (9 — selected-exclusive via partial unique index, Keychain pairing, URL round-trip, projection), `GRDBToolEnablementStoreTests` (3), `SettingRepositoryTests` (5), `CompactionCheckpointRepositoryTests` (5 — single-live invariant, conversation scoping).
    - **Total: 60 Chat tests across 11 suites, all green.** Core stays green (70 tests).
  - `xcodebuild -scheme Super -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build` succeeds.
  - Documentation: `///` doc comments on every public declaration; non-obvious functions carry parameter docs; record-level docs explain `apiKeyRef` is a Keychain ref (never the key itself), `parameters`/`result` on `ToolCallRecord` are JSON strings (caller serializes via `ToolCallRecord.encode(_:)`), the live-checkpoint semantics on `CompactionCheckpointRecord`, and that `MessageRole` is Chat-owned with an `asLLMRole()` translation. `docs/Chat/ARCHITECTURE.md` §3 documents the `MessageRole` enum + translation extension and explains the schema-independence rationale; §5 orchestrator samples use `.toolResult` to match.
  - Acronyms expanded on first use per project doc rules: SSE (Server-Sent Events), LLM (Large Language Model), JSON (JavaScript Object Notation), UI (User Interface), API (Application Programming Interface), FK (foreign key), SQL (Structured Query Language).

## M3 — OpenAI-compatible streaming

- **Checkbox**: `[x]` done
- **Status**: `done`
- **Last updated**: 2026-04-25
- **Notes**:
  - Source under `Packages/Chat/Sources/Chat/LLM/`:
    - `OpenAIWireTypes.swift` — internal Codable shapes for the OpenAI Chat Completions API (Application Programming Interface). Snake_case JSON ↔ camelCase Swift via `JSONEncoder/Decoder` key strategy. Request side: `OpenAIChatRequest` (with `streamOptions.includeUsage = true` so we get real token counts), `OpenAIRequestMessage`, `OutgoingToolCall`, `OpenAITool`, `OpenAIFunctionDefinition`. Response side: `OpenAIStreamChunk`, `OpenAIStreamChoice`, `OpenAIDelta` (carries `content`, `reasoningContent`, `reasoning`, `toolCalls`), `OpenAIToolCallDelta`, `OpenAIFunctionDelta`, `OpenAIUsage`.
    - `OpenAIStreamReducer.swift` — stateful struct turning chunks into `LLMStreamEvent`s. Owns: `emittedMessageStart` (single-fire across chunks), `nextBlockIndex` (our own monotonic block-index counter, distinct from OpenAI's choice index and per-call tool index), `openTextBlock` / `openThinkingBlock` (the currently open block of each kind, if any), `toolCallBuilders` (per-tool-index argument-fragment accumulators), `capturedUsage` (terminal token counts), `emittedComplete` (idempotency guard for `finish()`). Transitions: thinking arrives → close any open text block; text arrives → close any open thinking block; finishReason → close all open content blocks then flush tool calls in OpenAI-index order. Each tool call gets its own contentBlockStart/toolUse/contentBlockStop triplet. Malformed tool-call argument JSON throws `LLMError.decodingFailed` (a broken tool call breaks the turn semantically — no point in papering over it).
    - `OpenAICompatibleLLMProvider.swift` — public `LLMProvider` conformer. `init(id:displayName:model:baseURL:apiKey:http:)` (designated) plus `init(configuration:apiKey:http:)` (projects from `ModelConfiguration`). `apiKey` is optional so unauthenticated local servers (Ollama/LM Studio/MLX) just work — the `Authorization` header is omitted when nil/empty. Builds the URLRequest (`POST {baseURL}/chat/completions`, `Content-Type: application/json`, `Accept: text/event-stream`), drives `HTTPClient.stream` → `SSEParser` → JSON decode → reducer → yields `LLMStreamEvent`s. HTTP error mapping: 401/403 → `.unauthorized`, 429 → `.rateLimited`, other 4xx/5xx → `.providerError(code:message:)`. Tool parameters project to JSON Schema with `bool` → `boolean` translation at the boundary (Swift-friendly enum case names diverge from JSON Schema vocabulary). Tool-result `LLMMessage`s become per-result OpenAI `role: "tool"` rows with `tool_call_id`. Stream cancellation via `continuation.onTermination = { task.cancel() }`.
  - Tests under `Packages/Chat/Tests/ChatTests/LLM/`:
    - `OpenAIStreamReducerTests` (12 cases — messageStart-once, text deltas open & stream a block, reasoning opens a thinking block before text, text after thinking closes thinking and opens text, recognizes both `reasoning_content` and `reasoning` field names, tool-call argument fragments accumulate and decode to `JSONValue`, multiple tool calls flush in index order, malformed tool args throw `.decodingFailed`, `finish()` emits `messageComplete` with captured usage, `finish()` is idempotent, missing usage emits zero counts).
    - `OpenAICompatibleLLMProviderTests` (14 cases — fixture replay for plain/reasoning/toolcall/reasoning+tools, partial-chunk delivery via 17-slice subdivision (exercises the SSE parser), unsupported model throws before any HTTP request, 401→unauthorized / 429→rateLimited / 503→providerError mapping, malformed SSE data throws `.decodingFailed`, request URL and method, Authorization header presence/absence, body shape (model, messages, stream, temperature, stream_options.include_usage, tools), assistant-with-tool-uses + tool-result message round-trips encode correctly).
    - Helpers in `LLM/Helpers/`: `FakeHTTPClient` (records the issued `URLRequest`, replays configured byte chunks; `fromFixture(_:chunkCount:)` convenience splits a fixture into N slices to test partial-frame handling) and `FixtureLoader` (loads from `Bundle.module`'s `Fixtures/` subdirectory).
    - Fixtures (checked into `Packages/Chat/Tests/ChatTests/Fixtures/`, declared as `.copy("Fixtures")` resources on the test target): `openai-plain.txt`, `openai-reasoning.txt`, `openai-toolcall.txt`, `openai-reasoning-and-tools.txt`. Each follows the real OpenAI SSE wire format including `data: {...}\n\n` framing, the role-only first chunk, the trailing `data: [DONE]` sentinel, and a separate usage-only chunk.
    - Package.swift now declares `exclude: ["Database/__Snapshots__"]` to clear the M2-era snapshot resource warning.
    - **Total: 86 Chat tests across 13 suites, all green.** Core stays green (70 tests).
  - `xcodebuild -scheme Super -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build` succeeds.
  - Documentation: `///` doc comments on every public declaration and on the test suites; key acronyms expanded on first use per project doc rules: SSE (Server-Sent Events), JSON (JavaScript Object Notation), API (Application Programming Interface), HTTP (HyperText Transfer Protocol), I/O (Input/Output), BYOK (Bring Your Own Key).
  - Divergence from the plan path (`Packages/Chat/Tests/Fixtures/`): fixtures live under `Packages/Chat/Tests/ChatTests/Fixtures/` so they ride with the test target as a resource bundle (`Bundle.module`). The plan's path was a sketch; the SPM-conformant path is what actually ships.

## M4 — Session orchestration

- **Checkbox**: `[x]` done
- **Status**: `done`
- **Last updated**: 2026-04-25
- **Notes**:
  - Source under `Packages/Chat/Sources/Chat/Orchestration/`:
    - `ChatEvent.swift` — view-facing stream surface (`userMessageSaved`, `textDelta`, `thinkingDelta`, `toolCallStarted/Completed/Failed`, `assistantMessageSaved`, `error`). Always-finishes contract: failures arrive as `.error(LLMError)` immediately before stream termination, never as a thrown exception.
    - `ChatSession.swift` — actor; one per conversation. Public surface: `init(conversationId:messageRepository:toolCallRepository:llmProviderRegistry:toolRegistry:clock:idGenerator:)`, `send(text:model:temperature:) -> AsyncStream<ChatEvent>`, `cancel()`, `waitUntilFinished()`, `isStreaming`. Turn loop: write the user `MessageRecord` → loop { fetch all `MessageRecord` + `ToolCallRecord` rows for the conversation → assemble `[LLMMessage]` (assistant rows fold their tool-call rows in as `.toolUse` blocks; tool-result rows look up their originating call's `.failed` status to set `isError`) → drive `provider.stream(...)` with the currently-enabled tools (`toolRegistry.enabledTools(for:provider)` so disabled tools never reach the LLM) → buffer text in memory and persist the assistant `MessageRecord` only on `.messageComplete` (per ADR-BB-003) → save one `ToolCallRecord(.pending)` per requested call → execute each via `ToolRegistry` (status transitions `.executing` → `.success`/`.failed`) and write a tool-result `MessageRecord` (role `.tool`, `toolCallId` linkage) → loop }. The second `send(...)` while a turn is in flight cancels the prior task before starting a new one. `CancellationError` from inside tool execution is re-thrown (not caught as a tool failure) so the session terminates with `.error(.cancelled)` rather than marking the call `.failed`. Provider's `LLMError`s are forwarded as `.error` events. Missing active provider surfaces as `.error(.requestFailed(...))`.
    - `ChatSessionStore.swift` — actor; the app-level singleton over `[ConversationID: ChatSession]`. `session(for:)` is get-or-create (same instance on repeat calls so a streaming turn re-attaches when the view re-mounts). `cancel(for:)`, `shutdown()` (cancels every session and drops them), `runningConversations()` (sorted ids of sessions whose `isStreaming` is true; sidebar reads this for the per-row spinner).
    - Both actors take injected `Clock` and `IDGenerator` (Core's `Ambient/`) so tests can substitute deterministic doubles instead of calling `Date()` / `UUID()`.
  - Tests under `Packages/Chat/Tests/ChatTests/Orchestration/`:
    - Helpers (`Orchestration/Helpers/`): `FakeLLMProvider` (final class wrapping a private actor `FakeLLMProviderState`; `enqueue(_:)` queues per-turn `[LLMStreamEvent]` scripts; `capturedRequests()` records every issued request including model id, messages, tools, temperature; missing-script fallback returns a benign two-event sequence so forgotten enqueues don't hang). `FakeToolExecutor` (configurable `ToolResult` or `FakeToolError`; records every input). `OrchestrationFixtures` (in-memory `ChatDatabase`, default `LLMModel`, `seedConversation(...)`, plus `MonotonicClock` — auto-advances by 1 ms per `now()` call so back-to-back GRDB rows have strictly-increasing `createdAt` for the order-by-`createdAt` fetch).
    - `ChatSessionTests` (9 cases — user message persisted before any assistant write, text deltas accumulate and assistant saves once on `.messageComplete`, intermediate text deltas never write to DB (ADR-BB-003 regression test), provider `.error` event ends the turn with `.error` and no assistant row, missing active provider emits `.requestFailed`, prior messages pass to provider in chronological order, temperature forwards to provider, thinking deltas surface as `.thinkingDelta` events, `assistantMessageSaved` event carries the persisted row).
    - `ChatSessionStoreTests` (5 cases — same instance on repeat `session(for:)`, distinct instances per conversation, two sessions run in parallel to completion, cancelling one session does not affect siblings (synchronizes with a `SleepingToolExecutor`'s `awaitFirstCall()` so the cancellation lands inside `Task.sleep` deterministically), `shutdown()` cancels all and drops sessions).
    - `ChatSessionToolLoopTests` (4 cases — happy-path two-turn loop with tool execution, second-turn history correctly carries `.toolUse` and `.toolResult` blocks back to the LLM, tool execution failure marks `ToolCallRecord.failed` and feeds `isError: true` back to the LLM in the next turn, disabled tools are filtered before reaching the provider via `ToolRegistry.enabledTools(for:)`).
    - **Total: 115 Chat tests across 16 suites, all green.** Core stays green (70 tests).
  - `xcodebuild -scheme Super -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build` succeeds.
  - Documentation: `///` doc comments on every public declaration; turn-loop semantics, ADR-BB-003 rationale, cancellation behavior, and `MonotonicClock` justification all explained inline. Acronym expansions on first use per project doc rules: ID (Identifier), LLM (Large Language Model).
  - Divergence from the plan path (`Packages/Chat/Sources/Chat/Sessions/`): folder is `Orchestration/` to match the Chat module's `CLAUDE.md` directory convention.

## M5 — Compaction

- **Checkbox**: `[x]` done
- **Status**: `done`
- **Last updated**: 2026-04-25
- **Notes**:
  - Source under `Packages/Chat/Sources/Chat/Orchestration/`:
    - `TokenEstimator.swift` — `TokenEstimator` protocol + `HeuristicTokenEstimator` (chars/4, rounds up so 1–4 chars → 1 token). Default extension sums per-block cost across `[LLMMessage]`; tool-use payloads stringify their `JSONValue` input (sorted keys for stability) so verbose argument lists show up in the budget.
    - `ContextAssembler.swift` — `ContextAssembler` struct + `ContextAssembly` value (`messages`, `totalTokens`, `maxTokens`, `ratio`, `isOverThreshold(_:)`). Walks newest-first to find the cutoff implied by `checkpoint.uptoMessageId` (inclusive); messages at or before are dropped and the live checkpoint's `summary` is folded in as a synthetic system message ("Summary of earlier conversation (compacted):\n\n…") prepended to the kept tail. Any leading `.system` rows that the checkpoint window covered are re-emitted in front of the synthetic summary so the user's system prompt isn't summarized away. Unknown `uptoMessageId` falls back to the full history (lossy ignore beats silent truncation). Misconfigured `maxTokens <= 0` returns `ratio = 0` and never flags over-threshold.
    - `Compactor.swift` — `Compactor` actor + `CompactorError` (`emptySummary`, `llmError`). `compact(conversationId:messages:toolCalls:priorCheckpoint:model:keepMostRecent:)` returns the persisted new checkpoint (or `nil` when the post-checkpoint history has ≤ `keepMostRecent` messages — default 4). Stale `priorCheckpoint` (an `uptoMessageId` not in `messages`) falls back to the full message list. `wouldCompact(messages:priorCheckpoint:keepMostRecent:)` is a `nonisolated` pure predicate that mirrors the same `messagesToSummarize` slicing — used by `ChatSession`'s pre-flight so the two paths cannot diverge. Builds a summarization prompt: 3–8-sentence-summary system instruction, optional prior summary as a second system anchor, the projected `[LLMMessage]` slice to summarize, then a final user "summarize per the system instructions" trigger. Drives `provider.stream(...)` at temperature 0.2 (no tools), accumulates `.textDelta` into `summary`, throws on `.error` or empty result. Persisted checkpoint records `tokensBefore` (estimator over the full prompt sent to the LLM) and `tokensAfter` (estimator over the trimmed summary). `CompactionCheckpointRepository.save(_:)` demotes any prior live row in the same write transaction.
    - `SlashCommand.swift` — `SlashCommand` enum (currently just `.compact`); `init?(rawText:)` is whitespace-tolerant.
    - `ChatEvent.swift` — adds `.compactionStarted` and `.compactionCompleted(CompactionCheckpointRecord)` cases.
    - `ChatSession.swift` — new injected dependencies: `checkpointRepository`, `contextAssembler`, `compactor`, plus runtime-mutable `autoCompactEnabled` (default true) and `autoCompactThreshold` (default 0.75). New public `compact(model:)` returns its own `AsyncStream<ChatEvent>`. `send(text:model:)` first checks `SlashCommand(rawText:)` and routes to `compact(model:)` on `/compact` (no user `MessageRecord` is written). The turn loop calls `maybeAutoCompact(...)` before each turn — pre-flights via `ContextAssembler.isOverThreshold(autoCompactThreshold)` then runs `runCompactionPass(...)` which gates `.compactionStarted` on actually having something to summarize (prevents empty-banner flashes). `setAutoCompactPolicy(enabled:threshold:)` lets M9 settings push runtime updates into a long-running session. `assembleHistory(model:)` now delegates to `ContextAssembler` and runs the three repository fetches concurrently via `async let`.
    - `ChatSessionStore.swift` — threads `checkpointRepository`, `contextAssembler`, `compactor`, `autoCompactEnabled`, `autoCompactThreshold` into every `ChatSession` it creates.
  - Tests under `Packages/Chat/Tests/ChatTests/Orchestration/`:
    - `TokenEstimatorTests` (6 cases — empty → 0, short rounds up, English ratio, code overshoots within 4:1 bound, message rollup across all block kinds, tool-use input contributes to budget).
    - `ContextAssemblerTests` (8 cases — no checkpoint, with checkpoint drops covered messages and prepends summary, unknown checkpoint id falls back to full history, threshold classification at multiple ratios, ratio = 0 on invalid maxTokens, empty messages corner, **leading `.system` rows preserved across compaction**).
    - `CompactorTests` (8 cases — checkpoint persisted with correct uptoMessageId/summary/before-after token counts, prior live demoted in same transaction, returns nil when too few messages, empty provider summary throws `.emptySummary`, provider `.error` event bubbles as `.llmError`, summarization prompt carries prior summary verbatim, **stale prior checkpoint falls back to full history (predicate agrees)**, **`keepMostRecent` boundary: exactly 3 messages with `keepMostRecent = 2` summarizes one row**).
    - `ChatSessionCompactionTests` (5 cases — auto fires when over threshold and emits compactionStarted before completed before assistantSaved, disabling suppresses it even with same history, manual `/compact` works at any usage level and writes no user row, manual `/compact` with empty history is silent no-op, two concurrent sessions compact different conversations without racing the checkpoint table; **plus a negative regression: small history + small tool result → no spurious compaction event mid-tool-loop**).
    - `SlashCommandTests` (4 cases — exact match, whitespace tolerance, plain text returns nil, unknown commands return nil).
    - `Helpers/OrchestrationFixtures` gained `makeCompactor(database:llmRegistry:clock:idGenerator:)` so the existing test setups don't have to repeat the wiring.
  - Existing `ChatSession*` test setups updated to pass the new dependencies (and `autoCompactEnabled: false` so they keep their original turn-loop semantics — none of them were designed around compaction).
  - **Total: 153 Chat tests across 21 suites, all green.** Core stays green (70 tests).
  - `xcodebuild -scheme Super -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build` succeeds.
  - `Scripts/ChatLiveLLM/Sources/ChatLiveLLM/ChatLiveLLM.swift` updated: wires `GRDBCompactionCheckpointRepository` + `Compactor` into the in-memory store and renders the new `.compactionStarted` / `.compactionCompleted(...)` events to stdout.
  - Documentation: `///` doc comments on every public declaration (`TokenEstimator`, `HeuristicTokenEstimator`, `ContextAssembly`, `ContextAssembler`, `Compactor`, `CompactorError`, `SlashCommand`, the new `ChatEvent` cases, the new `ChatSession`/`ChatSessionStore` parameters). Acronyms expanded on first use per project doc rules: BPE (Byte-Pair Encoding), JSON (JavaScript Object Notation).
  - Settings keys (`autoCompactEnabled`, `autoCompactThreshold`) are wired through the constructor today; the M9 settings pane will read them from `SettingRecord` and call `ChatSession.setAutoCompactPolicy(enabled:threshold:)` to propagate runtime changes.

## M6 — Tool system + built-in tool

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `TimeNowTool` (the only real tool shipped in MVP). `RemoteHTTPToolExecutor` implemented + tested but nothing registered remote for v1.

## M7 — Chat UI

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: Pixel parity with `.design-tmp/chat/project/src/chat-view.jsx`. Single composer button flipping mic↔send. Three-theme support (Light / Dark / Sepia) with user-adjustable accent hue. Fonts bundled: Geist, Instrument Serif, JetBrains Mono.

## M8 — Sidebar drawer

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `SidebarDrawer` per `.design-tmp/chat/project/src/sidebar.jsx`. Applet rows for Todo/Recipes/Bible/Finance are visual placeholders (non-functional). Running chat spinner on leading edge of title.

## M9 — Settings

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: 9 panes total (Models, Theme, System Prompt, Default Verbosity, Appearance, Tools, Compaction, Data, About). Matches `.design-tmp/chat/project/src/settings.jsx` plus Tools and Compaction per user request.

## M10 — Markdown + code + thinking rendering

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: MarkdownUI + Splash. Block renderers match `.design-tmp/chat/project/src/message-parts.jsx`. Verbosity semantics: Simple collapses thinking+tool, Thinking expands thinking only, Verbose expands both. User toggles override.

## M11 — Voice input

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `SFSpeechRecognizer` on-device only. Invoked by the composer's trailing button when the field is empty. `NSSpeechRecognitionUsageDescription` + `NSMicrophoneUsageDescription` added to Info.plist.

## M12 — End-to-end polish + coverage

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: Coverage thresholds per AGENTS.md (Core ≥80%, applets ≥70%). Doc updates: add `ToolRegistration`, `ChatSessionStore`, `ContextAssembler`, `Compactor`, `CompactionCheckpointRecord`, `.thinkingDelta`, `.compactionStarted`/`.compactionCompleted` to the architecture docs; update `CLIENT_SERVER.md` to describe the MVP "no-server" mode.

---

## Notes for future sessions

- **Never rename files listed in the plan's Critical Files list without updating both the plan and this file.** Agents relying on grepped paths break silently otherwise.
- **Never re-record snapshot tests to "make them pass"** — per AGENTS.md §Testing, only re-record when the visual change is intentional and explained in the PR.
- **Never skip hooks** (`--no-verify`) or bypass tests — per AGENTS.md.
- **Module-boundary rule**: Chat imports Core. App imports Chat + Core. Nothing else. No cross-applet imports (though there's only one applet in MVP).
- **Never commit without running `swift test` in each touched package locally** — per AGENTS.md §Testing.3.
