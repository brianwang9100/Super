# PR-2: Compaction Boundary Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close audit P0-3 — the compaction cut must never split a tool round-trip, and the snap direction must never leave the kept window empty.

**Architecture:** PR-1 (#298) made `Compactor.messagesToSummarize` pair-aware by extending the cut **forward** through leading role-`.tool` rows. This PR flips the snap **backward** (the kept tail grows to absorb the whole pair group) and pins the surrounding seams with tests. PR-1's `ContextAssembler` synthesis/drop rules remain the projection-level backstop and are deliberately untouched.

**Tech Stack:** Swift 6, swift-testing, GRDB in-memory fixtures, `FakeLLMProvider` strict mock.

---

## Why backward, not forward (supersedes PR-1's choice)

The forward extension has a hard edge the PR-1 review didn't catch: when the raw
cut lands inside the trailing result run of a **≥4-parallel-call turn** (with the
default `keepMostRecent = 4`), the extension walks to the end of the history —
the kept window is **empty**. Consequences:

1. **Anthropic rejection.** `AnthropicNativeLLMProvider.translate` hoists every
   `.system` message (including the checkpoint summary) into the top-level
   `system` parameter, so the follow-up request ships an **empty `messages`
   array** — the Messages API rejects it. One failed turn mid-tool-loop, right
   after the model called its tools.
2. **Quality loss.** Auto-compaction fires at the top of every tool-loop
   iteration (`ChatSession.runTurnLoop` → `maybeAutoCompact`). Forward extension
   summarizes away the *freshest* tool results — the very data the model is
   mid-way through using — replacing them with a 3–8 sentence summary.

Backward snapping keeps the split pair **verbatim in the kept tail**, which is
what `keepMostRecent`'s doc says the carve-out is for ("the last tool round-trip
pair"). Invariants after the change:

- Summarize window never ends on an assistant row whose results are at/after
  the cut (we cut *before* that assistant row).
- Kept window never starts with a `.tool` row. *(Superseded — the final rule
  is stronger: the kept window opens on a `.user` row; see "Post-review
  revision" below.)*
- Kept window is never emptied by the snap (backward only grows it).
- Degenerate case: the pair group starts at the post-checkpoint window's index
  0 → cut walks to 0 → empty slice → `wouldCompact` false → silent no-op. That
  is correct: you can't summarize half a pair, and the no-op resolves itself as
  soon as the next user/assistant exchange pushes the pair fully inside the cut.
- `keepMostRecent: 0` (manual `/compact`) is unaffected: cut == count, the walk
  never runs, everything is summarized (trailing pairs ride inside the summary
  window intact — pair-complete prompt).

## Post-review revision (review M1)

The fable review of the first cut found that a `.tool`-only backward walk
always stops **on the issuing assistant row** — so every split-pair compaction
deterministically produced a kept window opening with an assistant message,
and Anthropic's Messages API requires the first message to be `user`-role
(every `.system` row is hoisted into the top-level `system` parameter). Two
changes over the plan as originally written:

1. **The walk condition is `role != .user`, not `role == .tool`.** The kept
   window always opens on a user turn — "compaction keeps whole turns, and a
   turn starts with a user message." One rule subsumes the tool-pair rule
   (results and their issuer both sit between user turns) and the
   first-message-must-be-user rule, for all providers. Tests updated
   accordingly (the kept tail now also includes the user turn that prompted a
   split pair; `autoCompactKeepsTrailingMessagesVerbatim` re-pins
   `defaultKeepMostRecent` as a floor, not an exact width).
2. **Legacy backstop in `AnthropicNativeLLMProvider.translate`:** checkpoints
   persisted by older builds can already carry an assistant-first kept window
   (the pre-PR-1 count-based cut), and an under-threshold conversation never
   re-compacts to heal it — so the adapter prepends a minimal synthetic user
   opener (`"(Conversation resumed after context compaction.)"`) when the
   grouped messages would otherwise start with an assistant turn. Two adapter
   tests pin the repair and its non-firing on healthy histories.

**Not in scope:** `ContextAssembler.messagesAfterCheckpoint` (audit P0-3's
"checkpoint index" clause). New checkpoints can no longer land mid-pair
(`uptoMessageId` is the last row of a slice that ends at a clean boundary), and
legacy mid-pair checkpoints are already repaired by PR-1's positional drop —
pinned by `checkpointCutBetweenPairDropsOrphanResultRow`. Adding a second snap
there would duplicate the projection contract for no wire-level gain.

## File Structure

- Modify: `Packages/Chat/Sources/Chat/Orchestration/Compactor.swift` (the
  `messagesToSummarize` while loop + doc comments — only production change)
- Modify: `Packages/Chat/Tests/ChatTests/Orchestration/CompactorTests.swift`
  (rewrite 2 forward-semantics tests, add 4)
- Modify: `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionToolLoopTests.swift`
  (1 new integration test: mid-loop auto-compaction with a 4-parallel-call turn)

---

### Task 1: Rewrite the two forward-semantics unit tests + add three boundary unit tests

**Files:**
- Modify: `Packages/Chat/Tests/ChatTests/Orchestration/CompactorTests.swift`

- [ ] **Step 1: Replace `summarizeCutExtendsThroughToolResultRows`** with the backward expectation:

```swift
/// The count-based cut must never split an assistant `tool_use` from
/// its role-`.tool` result rows. The cut snaps *backward* to just
/// before the assistant row that issued the calls, so the whole
/// round-trip stays verbatim in the kept tail. (Snapping forward —
/// PR-1's original rule — could consume the entire kept tail on a
/// wide parallel batch, leaving a follow-up request with no
/// non-system messages, which Anthropic rejects.)
@Test func summarizeCutSnapsBackBeforeSplitPair() {
    // 6 rows; keepMostRecent = 3 puts the raw cut on the first result
    // row of a two-call batch — splitting the pair.
    let rows = [
        makeRow(id: "m1", role: .user, offset: 0),
        makeRow(id: "m2", role: .assistant, offset: 1),
        makeRow(id: "m3", role: .assistant, offset: 2),          // issues tc-1, tc-2
        makeRow(id: "m4", role: .tool, offset: 3, toolCallId: "tc-1"),
        makeRow(id: "m5", role: .tool, offset: 4, toolCallId: "tc-2"),
        makeRow(id: "m6", role: .user, offset: 5),
    ]

    let slice = Compactor.messagesToSummarize(
        messages: rows, priorCheckpoint: nil, keepMostRecent: 3
    )

    // The cut walked back past m4 to land before the issuing assistant
    // row m3 — the kept tail is [m3, m4, m5, m6], pair intact.
    #expect(slice.map(\.id) == ["m1", "m2"])
}
```

- [ ] **Step 2: Replace `compactAcrossToolPairSummarizesThePairTogether`** with the kept-verbatim expectation (same fixture, new assertions):

```swift
/// End-to-end: compacting a history whose raw cut splits a tool pair
/// keeps the whole round-trip verbatim in the kept tail — the
/// summarization request carries no tool blocks at all, and the
/// checkpoint lands on the last row *before* the pair so the
/// post-checkpoint window opens with the issuing assistant row.
@Test func compactSplitPairStaysVerbatimInKeptTail() async throws {
    let setup = try await makeSetup(scripts: [
        [
            .messageStart(id: "s1", model: "fake-model-1"),
            .textDelta(index: 0, text: "Summary: the user asked for a lookup."),
            .messageComplete(usage: TokenUsage(inputTokens: 50, outputTokens: 12)),
        ],
    ])
    let messageRepo = GRDBMessageRepository(database: setup.database)
    let toolCallRepo = GRDBToolCallRepository(database: setup.database)

    // `makeRow` hardcodes "conv-1", which is the fixture conversation's id.
    let rows = [
        makeRow(id: "m1", role: .user, offset: 0),
        makeRow(id: "m2", role: .assistant, offset: 1),          // issues tc-1
        makeRow(id: "m3", role: .tool, offset: 2, toolCallId: "tc-1"),
        makeRow(id: "m4", role: .user, offset: 3),
        makeRow(id: "m5", role: .assistant, offset: 4),
    ]
    for row in rows {
        try await messageRepo.save(row)
    }
    let call = ToolCallRecord(
        id: "tc-1", messageId: "m2", conversationId: setup.conversation.id,
        toolName: "test.lookup", parameters: "{}",
        result: "{\"value\":42}", status: .success,
        createdAt: rows[1].createdAt, completedAt: rows[2].createdAt, signature: nil
    )
    try await toolCallRepo.save(call)

    // keepMostRecent = 3 → raw cut lands on m3 (the result row); the
    // pair-aware cut walks back before m2.
    let checkpoint = try await setup.compactor.compact(
        conversationId: setup.conversation.id,
        messages: rows,
        toolCalls: [call],
        priorCheckpoint: nil,
        model: setup.model,
        keepMostRecent: 3
    )

    #expect(checkpoint?.uptoMessageId == "m1")

    // The summarization request saw only m1 — no tool blocks, real or
    // synthesized.
    let request = try #require(await setup.provider.capturedRequests().last)
    for message in request.messages {
        for block in message.content {
            if case .toolUse = block { Issue.record("unexpected toolUse in summarization prompt") }
            if case .toolResult = block { Issue.record("unexpected toolResult in summarization prompt") }
        }
    }
    let projectedTexts = request.messages.flatMap(\.content).compactMap { block -> String? in
        if case .text(let value) = block { return value }
        return nil
    }
    #expect(projectedTexts.contains { $0.contains("content m1") })
    #expect(!projectedTexts.contains { $0.contains("content m2") })
}
```

- [ ] **Step 3: Add the parallel-batch test** (the case that broke forward extension):

```swift
/// A 4-parallel-call batch at the boundary must not empty the kept
/// tail: the backward snap lands before the issuing assistant row and
/// keeps the whole batch verbatim. (Forward extension would walk to
/// the end of history here — kept tail empty, follow-up request with
/// zero non-system messages.)
@Test func summarizeCutBacksOffWholeParallelBatch() {
    let rows = [
        makeRow(id: "m1", role: .user, offset: 0),
        makeRow(id: "m2", role: .assistant, offset: 1),
        makeRow(id: "m3", role: .user, offset: 2),
        makeRow(id: "m4", role: .assistant, offset: 3),          // issues tc-1...tc-4
        makeRow(id: "m5", role: .tool, offset: 4, toolCallId: "tc-1"),
        makeRow(id: "m6", role: .tool, offset: 5, toolCallId: "tc-2"),
        makeRow(id: "m7", role: .tool, offset: 6, toolCallId: "tc-3"),
        makeRow(id: "m8", role: .tool, offset: 7, toolCallId: "tc-4"),
    ]

    let slice = Compactor.messagesToSummarize(
        messages: rows, priorCheckpoint: nil, keepMostRecent: 4
    )

    #expect(slice.map(\.id) == ["m1", "m2", "m3"])
}
```

- [ ] **Step 4: Add the window-start no-op test:**

```swift
/// When the post-checkpoint window *opens* with a pair group and the
/// cut lands inside it, the backward walk reaches index 0 — there is
/// nothing that can be summarized without splitting the pair, so the
/// slice is empty and `wouldCompact` agrees (silent no-op, resolved
/// once later turns push the pair fully inside the cut).
@Test func summarizeCutInsideLeadingPairGroupIsANoOp() {
    let rows = [
        makeRow(id: "m1", role: .assistant, offset: 0),          // issues tc-1...tc-3
        makeRow(id: "m2", role: .tool, offset: 1, toolCallId: "tc-1"),
        makeRow(id: "m3", role: .tool, offset: 2, toolCallId: "tc-2"),
        makeRow(id: "m4", role: .tool, offset: 3, toolCallId: "tc-3"),
        makeRow(id: "m5", role: .user, offset: 4),
    ]

    let slice = Compactor.messagesToSummarize(
        messages: rows, priorCheckpoint: nil, keepMostRecent: 2
    )
    #expect(slice.isEmpty)

    // `wouldCompact` shares the slicing, so `runCompactionPass`'s
    // pre-flight and `compact` can never disagree on this shape.
    let compactor = Compactor(
        llmProviderRegistry: LLMProviderRegistry(),
        checkpointRepository: NullCompactionCheckpointRepository()
    )
    #expect(!compactor.wouldCompact(messages: rows, priorCheckpoint: nil, keepMostRecent: 2))
}
```

(If no `NullCompactionCheckpointRepository` exists, construct the compactor via `makeSetup()` inside an async test instead — `wouldCompact` is nonisolated and needs no scripts.)

- [ ] **Step 5: Add the manual-`/compact` (keep = 0) test:**

```swift
/// Manual `/compact` (`keepMostRecent: 0`) summarizes everything; a
/// trailing tool pair rides *inside* the summary window intact — the
/// prompt is pair-complete with the real result (no synthesized
/// "interrupted" claim) and the checkpoint lands on the final row.
@Test func keepZeroSummarizesTrailingPairComplete() async throws {
    let setup = try await makeSetup(scripts: [
        [
            .messageStart(id: "s1", model: "fake-model-1"),
            .textDelta(index: 0, text: "Summary: the tool ran and returned 42."),
            .messageComplete(usage: TokenUsage(inputTokens: 50, outputTokens: 12)),
        ],
    ])
    let messageRepo = GRDBMessageRepository(database: setup.database)
    let toolCallRepo = GRDBToolCallRepository(database: setup.database)

    let rows = [
        makeRow(id: "m1", role: .user, offset: 0),
        makeRow(id: "m2", role: .assistant, offset: 1),          // issues tc-1
        makeRow(id: "m3", role: .tool, offset: 2, toolCallId: "tc-1"),
    ]
    for row in rows {
        try await messageRepo.save(row)
    }
    let call = ToolCallRecord(
        id: "tc-1", messageId: "m2", conversationId: setup.conversation.id,
        toolName: "test.lookup", parameters: "{}",
        result: "{\"value\":42}", status: .success,
        createdAt: rows[1].createdAt, completedAt: rows[2].createdAt, signature: nil
    )
    try await toolCallRepo.save(call)

    let checkpoint = try await setup.compactor.compact(
        conversationId: setup.conversation.id,
        messages: rows,
        toolCalls: [call],
        priorCheckpoint: nil,
        model: setup.model,
        keepMostRecent: 0
    )

    #expect(checkpoint?.uptoMessageId == "m3")

    let request = try #require(await setup.provider.capturedRequests().last)
    var sawToolUse = false
    var resultContents: [String] = []
    for message in request.messages {
        for block in message.content {
            if case .toolUse("tc-1", _, _, _) = block { sawToolUse = true }
            if case .toolResult("tc-1", let content, _) = block { resultContents.append(content) }
        }
    }
    #expect(sawToolUse)
    #expect(resultContents == ["content m3"])
}
```

- [ ] **Step 6: Run the Compactor suite to verify the rewritten tests fail** (backward not yet implemented):

Run: `cd Packages/Chat && swift test --filter CompactorTests`
Expected: `summarizeCutSnapsBackBeforeSplitPair`, `compactSplitPairStaysVerbatimInKeptTail`, `summarizeCutBacksOffWholeParallelBatch`, `summarizeCutInsideLeadingPairGroupIsANoOp` FAIL (forward semantics produce different slices). `keepZeroSummarizesTrailingPairComplete` and `summarizeCutOnTurnBoundaryIsUnchanged` PASS (behavior identical under both rules).

### Task 2: Add the ChatSession mid-loop integration test

**Files:**
- Modify: `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionToolLoopTests.swift`

- [ ] **Step 1: Write the failing integration test.** Mirror the suite's `makeSetup` but with auto-compaction enabled, a near-zero threshold, and a full-tier model (the default fixture model is 8,192 tokens = compact tier, which gates on the compressible ratio and filters tools):

```swift
/// Auto-compaction fires at the top of *every* tool-loop iteration —
/// including the follow-up right after tool results persist. When the
/// cut would split the just-executed 4-call batch, the backward snap
/// keeps the whole round-trip verbatim: the follow-up request must
/// carry the assistant's four `toolUse` blocks with all four real
/// results (no synthesized "interrupted" text) plus the fresh
/// checkpoint summary, and the checkpoint must land on a clean
/// turn boundary.
@Test func midLoopAutoCompactionKeepsFollowUpPairComplete() async throws {
    let toolID = "test.batch"
    let database = try ChatDatabase.makeInMemory()
    let messageRepo = GRDBMessageRepository(database: database)
    let toolCallRepo = GRDBToolCallRepository(database: database)
    let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
    let clock = OrchestrationFixtures.defaultClock()
    let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
    let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

    // Full-tier window so `maybeAutoCompact` uses the plain total-ratio
    // gate; near-zero threshold so it fires on every iteration.
    let model = LLMModel(
        id: "fake-model-1", displayName: "Fake Model",
        supportsThinking: false, supportsTools: true,
        maxContextTokens: 200_000
    )
    let provider = FakeLLMProvider(model: model)
    let llmRegistry = LLMProviderRegistry()
    await llmRegistry.register(provider)
    let toolRegistry = ToolRegistry()
    let compactor = OrchestrationFixtures.makeCompactor(
        database: database, llmRegistry: llmRegistry, clock: clock, idGenerator: idGen
    )
    let session = ChatSession(
        conversationId: conversation.id,
        messageRepository: messageRepo,
        toolCallRepository: toolCallRepo,
        checkpointRepository: checkpointRepo,
        llmProviderRegistry: llmRegistry,
        toolRegistry: toolRegistry,
        compactor: compactor,
        clock: clock,
        idGenerator: idGen,
        autoCompactEnabled: true,
        autoCompactThreshold: 0.000_001
    )

    // 6 seeded rows + the new user row = 7 at iteration 1, so the
    // first compaction has history to chew on.
    for index in 1...3 {
        try await messageRepo.save(MessageRecord(
            id: "seed-u\(index)", conversationId: conversation.id, role: .user,
            content: "seeded user \(index)", createdAt: clock.now()
        ))
        try await messageRepo.save(MessageRecord(
            id: "seed-a\(index)", conversationId: conversation.id, role: .assistant,
            content: "seeded reply \(index)", createdAt: clock.now()
        ))
    }

    // Script order is the loop's consumption order:
    //   1. iteration-1 compaction summary
    //   2. turn 1: a 4-parallel-call batch
    //   3. iteration-2 compaction summary (the mid-loop pass under test)
    //   4. the follow-up turn after tool results
    await provider.enqueue([
        .messageStart(id: "sum-1", model: "fake-model-1"),
        .textDelta(index: 0, text: "Summary one: earlier seeded chatter."),
        .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
    ])
    await provider.enqueue([
        .messageStart(id: "m1", model: "fake-model-1"),
        .textDelta(index: 0, text: "running four lookups"),
        .toolUse(index: 0, id: "tc-1", name: toolID, input: .object([:]), signature: nil),
        .toolUse(index: 1, id: "tc-2", name: toolID, input: .object([:]), signature: nil),
        .toolUse(index: 2, id: "tc-3", name: toolID, input: .object([:]), signature: nil),
        .toolUse(index: 3, id: "tc-4", name: toolID, input: .object([:]), signature: nil),
        .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
    ])
    await provider.enqueue([
        .messageStart(id: "sum-2", model: "fake-model-1"),
        .textDelta(index: 0, text: "Summary two: the user asked for four lookups."),
        .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
    ])
    await provider.enqueue([
        .messageStart(id: "m2", model: "fake-model-1"),
        .textDelta(index: 0, text: "all four came back fine"),
        .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
    ])

    let executor = FakeToolExecutor(toolID: toolID)
    await executor.setResult(ToolResult(toolID: toolID, content: "ok", isError: false))
    await toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

    let stream = await session.send(text: "look up four things", model: model)
    _ = await collect(stream)
    await session.waitUntilFinished()

    // Two compaction passes ran; the live checkpoint is iteration 2's,
    // landed on the user row — the clean boundary just before the
    // 4-call assistant turn (not the assistant row, not a result row).
    let live = try #require(await checkpointRepo.liveCheckpoint(for: conversation.id))
    #expect(live.summary.contains("Summary two"))
    let storedRows = try await messageRepo.fetchAll(conversationId: conversation.id)
    let uptoRow = try #require(storedRows.first { $0.id == live.uptoMessageId })
    #expect(uptoRow.role == .user)
    #expect(uptoRow.content == "look up four things")

    // The follow-up request (the last captured) is pair-complete: the
    // assistant turn with all four toolUse blocks survived the
    // checkpoint verbatim, each with its real result — and no
    // synthesized "interrupted" repair text anywhere.
    let request = try #require(await provider.capturedRequests().last)
    var toolUseIDs: [String] = []
    var resultsByID: [String: String] = [:]
    for message in request.messages {
        for block in message.content {
            if case .toolUse(let id, _, _, _) = block { toolUseIDs.append(id) }
            if case .toolResult(let id, let content, _) = block { resultsByID[id] = content }
        }
    }
    #expect(toolUseIDs.sorted() == ["tc-1", "tc-2", "tc-3", "tc-4"])
    #expect(resultsByID.keys.sorted() == ["tc-1", "tc-2", "tc-3", "tc-4"])
    #expect(resultsByID.values.allSatisfy { $0 == "ok" })
    let allText = request.messages.flatMap(\.content).compactMap { block -> String? in
        if case .text(let value) = block { return value }
        return nil
    }.joined(separator: "\n")
    #expect(!allText.contains("interrupted"))
    #expect(allText.contains("Summary two"))
}
```

- [ ] **Step 2: Run it to verify it fails under forward semantics:**

Run: `cd Packages/Chat && swift test --filter midLoopAutoCompactionKeepsFollowUpPairComplete`
Expected: FAIL — forward extension swallows the batch into checkpoint 2 (`uptoRow.role == .tool`, follow-up request has no toolUse blocks).

### Task 3: Flip the snap direction in `Compactor.messagesToSummarize`

**Files:**
- Modify: `Packages/Chat/Sources/Chat/Orchestration/Compactor.swift:141-153` (+ the doc comment above it, + `compact`'s `- Returns:` note)

- [ ] **Step 1: Replace the forward walk with the backward walk and rewrite the rationale comment:**

```swift
    /// Single source of truth for "which messages should this compaction
    /// pass actually summarize." Used both by `compact(...)`'s body and
    /// `wouldCompact(...)`'s pre-flight so the two paths cannot drift.
    /// Stale `priorCheckpoint` (an `uptoMessageId` not present in
    /// `messages`) falls back to the full message list — losing the tail
    /// is worse than ignoring a stale row.
    ///
    /// The cut never splits a tool pair: role-`.tool` result rows directly
    /// follow the assistant row that issued the calls, so a kept tail that
    /// would *start* with result rows means the raw count-based cut landed
    /// inside a pair group. The cut snaps **backward** to just before the
    /// issuing assistant row, keeping the whole round-trip verbatim in the
    /// kept tail (which is what `keepMostRecent`'s carve-out exists for).
    /// Snapping forward instead would summarize away the freshest tool
    /// results mid-loop and — on a parallel batch wider than the kept
    /// count — empty the kept window entirely, leaving a follow-up
    /// request with no non-system messages (Anthropic rejects those:
    /// its adapter hoists every `.system` row into the top-level
    /// `system` parameter). If the pair group opens the post-checkpoint
    /// window the walk reaches index 0 and the slice comes back empty —
    /// a deliberate no-op (`wouldCompact` returns false) that resolves
    /// once later turns push the pair fully inside the cut.
    static func messagesToSummarize(
        messages: [MessageRecord],
        priorCheckpoint: CompactionCheckpointRecord?,
        keepMostRecent: Int
    ) -> [MessageRecord] {
        let postCheckpoint = messagesAfterCheckpoint(messages, checkpoint: priorCheckpoint)
        guard postCheckpoint.count > keepMostRecent else { return [] }
        var cut = postCheckpoint.count - max(0, keepMostRecent)
        while cut > 0, cut < postCheckpoint.count, postCheckpoint[cut].role == .tool {
            cut -= 1
        }
        return Array(postCheckpoint[..<cut])
    }
```

- [ ] **Step 2: Update `compact(...)`'s `- Returns:` doc** to mention the new nil case:

```swift
    /// - Returns: The persisted new checkpoint, or nil when there's
    ///   nothing to summarize (fewer than `keepMostRecent + 1` messages
    ///   beyond the prior checkpoint, or the would-be slice would split
    ///   a tool round-trip that opens the post-checkpoint window).
```

- [ ] **Step 3: Run the full Chat suite:**

Run: `cd Packages/Chat && swift test`
Expected: PASS, including all rewritten/new tests.

- [ ] **Step 4: Commit.**

### Task 4: Review, PR, merge

- [ ] **Step 1:** Dispatch a fable review subagent over the diff; fix MUST/SHOULD findings.
- [ ] **Step 2:** `gh pr create` with a Test Coverage section; iterate the claude-review loop to APPROVE; `gh pr merge --squash --auto`.
- [ ] **Step 3:** After merge: update the audit worktree's `AUDIT_6_11_2026.md` (mark P0-3 closed) and the roadmap memory. Stop per workflow.
