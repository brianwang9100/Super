# PR-4: Gemini id-less tool-call disambiguation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close audit P1-6 — a second assistant turn calling the same *id-less* (legacy Gemini) tool in one conversation silently re-parents the earlier turn's `ToolCallRecord` (PK upsert collision), so the earlier assistant message loses its `toolUse` in projection while its `tool_result` row survives → orphaned result → strict-provider 400.

**Architecture:** Disambiguate the persisted PK at the `ChatSession` save seam. When the provider supplied no id (detected the same way the Gemini adapter already detects it: `call.id == call.name`), mint a locally-unique, marked PK (`localtoolu_<generatedID>`) instead of the bare tool name. The marker travels with the id into the projected `.toolUse` block, so the Gemini adapter recognizes it and still emits **name-only** on the wire (byte-identical to today — no fabricated id leaks to Gemini, the round-trip-sensitive provider). Strict providers (Anthropic/OpenAI) receive the unique marked id, which is exactly what they need (no duplicate `tool_use` ids across turns). The in-turn reducer contract from PR #243 is unchanged; no migration and no new column — the PK is a value, not a schema change.

**Tech Stack:** Swift 6, swift-testing, GRDB, `FakeLLMProvider`, `FakeHTTPClient` + `decodeBody`.

---

## Ground truth (verified 2026-06-12 against the code)

1. **The collision is a GRDB upsert on the PK.** `ToolCallRecord.id` is the `toolCall` table primary key; `GRDBToolCallRepository.save` upserts. `ChatSession.persistAssistantTurn` (~line 1273) writes `ToolCallRecord(id: call.id, …)` where `call.id` is the reducer's value. For id-less Gemini calls the reducer emits `call.id ?? name == name` (`GeminiStreamReducer.swift:171`), so two turns calling tool `foo` both persist with `id == "foo"` → the second `save` overwrites the first row's `messageId`.

2. **Re-parenting produces an orphaned `tool_result`.** After the overwrite, `toolCallsByMessageID[turn1.id]` is empty, so turn 1's assistant message projects with **no** `toolUse`. Turn 1's `.tool` result row still references `"foo"`, and `"foo"` *is* in `projectedToolUseIDs` (from turn 2's `toolUse`), so the result row projects — but it now sits before turn 2's `toolUse`. Orphaned `tool_result` → Anthropic/OpenAI 400.

3. **Result rows already key on the PK.** Every result-row stamp uses `toolCallId: record.id` (`ChatSession.swift:823, 865, 1344, 1410, 1430`), and `executeToolCalls` operates on the returned `savedCalls`. So disambiguating the PK at the save seam propagates to the result rows automatically — no execution-path change needed.

4. **The Gemini wire id is gated on `id == name`.** `GeminiNativeLLMProvider.translate` emits `functionCall.id` / `functionResponse.id` only when `id != name` (`:308, :338`); for id-less turns (`id == name`) it sends name-only, byte-identical to a native id-less conversation. A unique synthetic PK (`localtoolu_…`) makes `id != name`, which would *leak the synthetic id onto the Gemini wire* unless the adapter also recognizes the marker — hence the marker check.

5. **Strict adapters pass `block.id` straight through.** `AnthropicNativeLLMProvider.translate:415-416` and `OpenAICompatibleLLMProvider.translate:268` emit `block.id` as the wire `tool_use` / `tool_call` id. So a unique PK gives them unique ids — which is what they require; bare-name-repeated-across-turns would risk a duplicate-id 400 there. The marked PK fixes both the orphan (Gemini) and the duplicate-id (strict) failure modes at once.

6. **`id == name` is a safe id-less signal at the persist seam.** The Gemini reducer is the only conformer that emits `id == name` (its documented id-less fallback). Anthropic ids are `toolu_…`, OpenAI `call_…` — never a bare tool name. The Gemini adapter already relies on this exact equivalence, so reusing it at the persist seam is consistent, not a new assumption.

## Design

**Marker convention (new, `ToolCallRecord` statics):**
- `static let locallyMintedIDPrefix = "localtoolu_"` — distinct from provider id shapes (`toolu_`, `call_`, Gemini opaque tokens).
- `static func locallyMintedID(_ raw: String) -> String { locallyMintedIDPrefix + raw }`
- `static func isLocallyMintedID(_ id: String) -> Bool { id.hasPrefix(locallyMintedIDPrefix) }`

**Persist seam (`ChatSession.persistAssistantTurn`, ~1270-1287):** when `call.id == call.name` (provider gave no id), persist `id: ToolCallRecord.locallyMintedID(idGenerator.nextID())`; otherwise persist `call.id` verbatim. `idGenerator` is the injected generator already used for the assistant message id one block up, so it's deterministic in tests and unique even for same-turn parallel same-tool calls (a bonus hardening over the pre-#243 same-turn collision).

**Gemini adapter (`translate`, two spots):** replace the bare `id == name` / `toolUseID == name` checks with a shared `sendsNameOnly` predicate: `id == name || ToolCallRecord.isLocallyMintedID(id)`. Locally-minted ids → name-only (byte-identical to today); legacy id-less rows (`id == name`, persisted before this PR) → still name-only; real Gemini ids → sent verbatim.

**No change to** the reducer (PR #243 in-turn contract intact), `ContextAssembler` (projects `call.id` verbatim — now unique for new id-less calls, so the pairing/totality logic naturally keeps both turns' rows), the schema (PK is a value), or the strict adapters (they pass the unique id through).

**Legacy rows (persisted before this PR):** old id-less rows keep bare-name PKs. Gemini still sends name-only for them via the `id == name` arm. They retain the theoretical cross-provider duplicate-id edge for *historical* data only; not migrated (a PK rewrite would have to retarget every `message.toolCallId` in lockstep — disproportionate for rare, Gemini-only legacy rows). New conversations are fully correct across all providers. Documented in the PR.

**Out of scope:** same-turn parallel *same-name id-less* calls remain indistinguishable to Gemini on the wire (name-only collides by name) — an inherent id-less-Gemini limitation (#243's note: "which is why newer models supply the id"); the fix still stores them as distinct rows (no crash/re-parent) and disambiguates them for strict providers. Provider-id-reuse-across-turns by Gemini (if it ever happens) is not addressed.

## File Structure

- Modify: `Packages/Chat/Sources/Chat/Models/ToolCallRecord.swift` — marker statics + doc on the `id` field.
- Modify: `Packages/Chat/Sources/Chat/Orchestration/ChatSession.swift` — mint the disambiguated PK at the persist seam.
- Modify: `Packages/Chat/Sources/Chat/LLM/GeminiNativeLLMProvider.swift` — `sendsNameOnly` predicate at the two wire-id sites + doc update.
- Tests:
  - `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionToolLoopTests.swift` — cross-turn id-less collision (the required fail-first test).
  - `Packages/Chat/Tests/ChatTests/LLM/GeminiNativeLLMProviderTests.swift` — locally-minted id stays name-only on the wire; strengthen the existing id-less test with an explicit `id == nil` assertion; real id still sent.
  - `Packages/Chat/Tests/ChatTests/Models/ToolCallRecordTests.swift` (or inline) — marker helper round-trip.

## Tasks (TDD; fail-first)

### Task 1: Marker convention on `ToolCallRecord`

- [ ] **Step 1 — failing test.** In a new `Models/ToolCallRecordTests.swift` (or the nearest existing model-test suite), assert:
  ```swift
  @Test func locallyMintedIDIsPrefixedAndRecognized() {
      let minted = ToolCallRecord.locallyMintedID("id-7")
      #expect(minted == "localtoolu_id-7")
      #expect(ToolCallRecord.isLocallyMintedID(minted))
      #expect(!ToolCallRecord.isLocallyMintedID("toolu_abc"))   // Anthropic
      #expect(!ToolCallRecord.isLocallyMintedID("get_weather")) // bare name
  }
  ```
- [ ] **Step 2 — run, expect fail** (`locallyMintedID`/`isLocallyMintedID` undefined).
- [ ] **Step 3 — implement.** Add to `ToolCallRecord`:
  ```swift
  /// Prefix marking a tool-call id we minted locally because the provider
  /// supplied none (legacy id-less Gemini calls). Distinct from every
  /// provider's id shape (`toolu_`, `call_`, Gemini's opaque tokens) so the
  /// Gemini adapter can recognize a synthetic id and still emit name-only on
  /// the wire — a fabricated id must never reach Gemini, which round-trips
  /// the ids it minted. Strict providers receive the marked id verbatim
  /// (they require unique `tool_use` ids; the marker is just a unique string).
  public static let locallyMintedIDPrefix = "localtoolu_"
  public static func locallyMintedID(_ raw: String) -> String { locallyMintedIDPrefix + raw }
  public static func isLocallyMintedID(_ id: String) -> Bool { id.hasPrefix(locallyMintedIDPrefix) }
  ```
  Update the `id` field doc to note it is locally unique (not necessarily the provider's wire id) for id-less calls.
- [ ] **Step 4 — run, expect pass.**
- [ ] **Step 5 — commit** (`feat(chat): mark locally-minted tool-call ids`).

### Task 2: Disambiguate the persisted PK (the fix + required cross-turn test)

- [ ] **Step 1 — failing test** in `ChatSessionToolLoopTests.swift`. Script one `send` that loops three turns: turn 1 emits an id-less tool call (`id == name`), turn 2 emits the *same* id-less tool call again, turn 3 finishes with text. (Two id-less assistant tool turns in one conversation — the audit's "second turn calling the same tool".)
  ```swift
  @Test func idlessToolCallsAcrossTurnsPersistAsDistinctRowsAndKeepEarlierToolUse() async throws {
      let toolID = "get_weather"
      let setup = try await makeSetup(scripts: [
          [ .messageStart(id: "m1", model: "fake-model-1"),
            .toolUse(index: 0, id: toolID, name: toolID, input: .object(["c": .string("Paris")]), signature: nil),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)) ],
          [ .messageStart(id: "m2", model: "fake-model-1"),
            .toolUse(index: 0, id: toolID, name: toolID, input: .object(["c": .string("London")]), signature: nil),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)) ],
          [ .messageStart(id: "m3", model: "fake-model-1"),
            .textDelta(index: 0, text: "done"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)) ],
      ])
      let executor = FakeToolExecutor(toolID: toolID)
      await executor.setResult(ToolResult(toolID: toolID, content: "ok", isError: false))
      await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

      _ = await collect(await setup.session.send(text: "weather twice", model: setup.model))
      await setup.session.waitUntilFinished()

      // Two distinct ToolCallRecord rows survive — no upsert re-parent.
      let calls = try await setup.toolCallRepo.fetchAll(conversationId: setup.conversation.id)
          .sorted { $0.createdAt < $1.createdAt }
      #expect(calls.count == 2)
      #expect(Set(calls.map(\.id)).count == 2)              // distinct PKs
      #expect(calls.allSatisfy { $0.toolName == toolID })
      #expect(calls.allSatisfy { ToolCallRecord.isLocallyMintedID($0.id) })
      #expect(calls[0].messageId != calls[1].messageId)     // parented to different turns

      // The final assembling request (turn 3) carries BOTH assistant tool turns,
      // each with its own toolUse — turn 1 did not lose its call, and the two
      // wire ids are distinct (strict-provider duplicate-id safety).
      let lastRequest = try #require(await setup.provider.capturedRequests().last)
      let toolUseIDs = lastRequest.messages.flatMap { msg in
          msg.content.compactMap { block -> String? in
              if case .toolUse(let id, _, _, _) = block { return id }
              return nil
          }
      }
      #expect(toolUseIDs.count == 2)
      #expect(Set(toolUseIDs).count == 2)
  }
  ```
  (Confirm `GRDBToolCallRepository` exposes `fetchAll(conversationId:)`; if the accessor differs, adapt — the existing suite fetches single rows by id, so check the repo API first and use the closest list accessor or fetch the two ids.)
- [ ] **Step 2 — run, expect fail** (today: `calls.count == 1`, the second upserts over the first).
- [ ] **Step 3 — implement** in `ChatSession.persistAssistantTurn`'s `for call in pendingCalls` loop:
  ```swift
  // A provider that supplies no tool-call id (legacy id-less Gemini — the
  // reducer falls back to the tool name, so id == name) would collide the PK
  // across turns: the GRDB upsert re-parents the earlier turn's row, orphaning
  // its tool_result on replay. Mint a locally-unique, marked id instead. The
  // marker lets the Gemini adapter still emit name-only on the wire (byte-
  // identical, no fabricated id), while strict providers get a unique id.
  let persistedID = call.id == call.name
      ? ToolCallRecord.locallyMintedID(idGenerator.nextID())
      : call.id
  let record = ToolCallRecord(
      id: persistedID,
      messageId: assistantMessage.id,
      …
  )
  ```
- [ ] **Step 4 — run, expect pass.** Also run `loopExecutesToolThenContinuesUntilLLMFinishesWithoutToolCalls` — it scripts `id: "tc-1"` (a real id, `id != name`) so it must be unaffected; if it now fails, the detection is wrong.
- [ ] **Step 5 — commit** (`fix(chat): disambiguate id-less tool-call PKs across turns (audit P1-6)`).

### Task 3: Keep the Gemini wire name-only for marked ids

- [ ] **Step 1 — failing test** in `GeminiNativeLLMProviderTests.swift`: a history whose `toolUse.id` is a locally-minted marked id must still produce a name-only `functionCall` and `functionResponse` (no `id` key) on the wire.
  ```swift
  @Test func locallyMintedToolCallIDStaysNameOnlyOnTheWire() async throws {
      let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
      let minted = ToolCallRecord.locallyMintedID("id-3")   // localtoolu_id-3
      let history: [LLMMessage] = [
          LLMMessage(role: .assistant, content: [
              .toolUse(id: minted, name: "get_weather", input: .object(["c": .string("Paris")]), signature: nil),
          ]),
          LLMMessage(role: .tool, content: [
              .toolResult(toolUseID: minted, content: "18C", isError: false),
          ]),
      ]
      _ = try await collect(makeProvider(http: http).stream(
          messages: history, model: model, tools: [], temperature: 0.5
      ))
      let body = try Self.decodeBody(http)
      let contents = try #require(body["contents"] as? [[String: Any]])
      let call = try #require((contents[0]["parts"] as? [[String: Any]])?.first { $0["functionCall"] != nil }?["functionCall"] as? [String: Any])
      #expect(call["name"] as? String == "get_weather")
      #expect(call["id"] == nil)                                   // synthetic id must NOT leak
      let resp = try #require((contents[1]["parts"] as? [[String: Any]])?.first { $0["functionResponse"] != nil }?["functionResponse"] as? [String: Any])
      #expect(resp["name"] as? String == "get_weather")
      #expect(resp["id"] == nil)
  }
  ```
  Also strengthen `toolResultBecomesFunctionResponseOnAUserContent` with `#expect(functionCall["id"] == nil)` and `#expect(functionResponse["id"] == nil)` (locks the legacy `id == name` name-only path).
- [ ] **Step 2 — run, expect fail** (today `minted != name` → the adapter emits `id: "localtoolu_id-3"`).
- [ ] **Step 3 — implement** in `GeminiNativeLLMProvider.translate`. Add a small predicate and use it at both sites:
  ```swift
  // A tool-call id is sent on the Gemini wire only when the provider minted
  // it. Bare-name fallbacks (legacy id-less, id == name) and locally-minted
  // ids (disambiguated PKs we created because the provider gave none) are
  // synthetic — Gemini round-trips the ids IT minted, so a fabricated id must
  // not reach it; send name-only (byte-identical to a native id-less turn).
  func sendsNameOnly(id: String, name: String) -> Bool {
      id == name || ToolCallRecord.isLocallyMintedID(id)
  }
  ```
  functionResponse site (~307): `let wireID = sendsNameOnly(id: toolUseID, name: name) ? nil : toolUseID`.
  functionCall site (~338): `let wireID = sendsNameOnly(id: id, name: name) ? nil : id`.
  Update the `translate` doc note to mention locally-minted ids are also sent name-only.
- [ ] **Step 4 — run, expect pass.** Run the existing parallel-id test (`call-paris`/`call-london`, `id != name`, unmarked) — must still send ids.
- [ ] **Step 5 — commit** (`fix(chat): keep locally-minted tool-call ids off the Gemini wire`).

### Task 4: Suites, review, PR

- [ ] `swift test -Xswiftc -warnings-as-errors` in `Packages/Chat` (and `Packages/Core` if any Core file is touched — none planned). All green.
- [ ] Review subagent (default model — `fable` is unavailable) → fix MUST/SHOULD.
- [ ] PR with a Test Coverage section. Note the legacy-row limitation (old bare-name id-less rows are not migrated) and that no live-API key was available, but unlike PR-3 the change is provider-shape-deterministic and fully covered by wire-shape assertions, so the live-API risk is low (call out the one happy-path Gemini multi-tool-turn round-trip to spot-check when a key is available).
- [ ] claude-review loop → APPROVE → squash auto-merge → STOP (pause per the per-PR workflow).
