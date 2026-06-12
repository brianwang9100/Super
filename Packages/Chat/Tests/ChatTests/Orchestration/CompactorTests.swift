import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `Compactor` — issues a summarization turn through a fake
/// `LLMProvider`, persists a `CompactionCheckpointRecord`, and demotes
/// any prior live one in the same write.
@Suite("Compactor")
struct CompactorTests {

    private struct Setup {
        let database: ChatDatabase
        let checkpointRepo: GRDBCompactionCheckpointRepository
        let llmRegistry: LLMProviderRegistry
        let provider: FakeLLMProvider
        let model: LLMModel
        let compactor: Compactor
        let conversation: ConversationRecord
        let clock: FixedClock
        let idGen: DeterministicIDGenerator
    }

    private func makeSetup(scripts: [[LLMStreamEvent]] = []) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "ck-", start: 0)
        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        for script in scripts { await provider.enqueue(script) }
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let compactor = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGen
        )
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)
        return Setup(
            database: database,
            checkpointRepo: checkpointRepo,
            llmRegistry: llmRegistry,
            provider: provider,
            model: model,
            compactor: compactor,
            conversation: conversation,
            clock: clock,
            idGen: idGen
        )
    }

    /// 10 user/assistant pairs — enough to leave plenty of summarizable
    /// history beyond the default `keepMostRecent = 4`.
    private func seedPlentyOfMessages(setup: Setup) async throws -> [MessageRecord] {
        let messageRepo = GRDBMessageRepository(database: setup.database)
        var rows: [MessageRecord] = []
        for index in 1...10 {
            let user = MessageRecord(
                id: "m-u\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: "user message \(index)",
                createdAt: setup.clock.now()
            )
            try await messageRepo.save(user)
            rows.append(user)
            let assistant = MessageRecord(
                id: "m-a\(index)",
                conversationId: setup.conversation.id,
                role: .assistant,
                content: "assistant reply \(index)",
                createdAt: setup.clock.now()
            )
            try await messageRepo.save(assistant)
            rows.append(assistant)
        }
        return rows
    }

    @Test func compactPersistsNewLiveCheckpointWithCorrectFields() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-1", model: "fake-model-1"),
                .textDelta(index: 0, text: "Summary: they exchanged 8 greetings."),
                .messageComplete(usage: TokenUsage(inputTokens: 50, outputTokens: 8)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)

        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: nil,
            model: setup.model
        )

        #expect(checkpoint != nil)
        let saved = try #require(checkpoint)
        // The checkpoint covers everything except the last 4 messages
        // (default keepMostRecent). With 20 messages total, that's the
        // 16th in 1-indexed order — `m-a8`.
        #expect(saved.uptoMessageId == "m-a8")
        #expect(saved.summary.contains("Summary: they exchanged 8 greetings"))
        #expect(saved.isLive)
        #expect(saved.tokensBefore > saved.tokensAfter)

        // Also persisted: the live checkpoint readable back.
        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live?.id == saved.id)
    }

    @Test func compactDemotesPriorLiveCheckpointInSameTransaction() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-2", model: "fake-model-1"),
                .textDelta(index: 0, text: "Updated summary."),
                .messageComplete(usage: TokenUsage(inputTokens: 60, outputTokens: 4)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)

        // Pre-existing live checkpoint covering an earlier window.
        let prior = CompactionCheckpointRecord(
            id: "ck-prior",
            conversationId: setup.conversation.id,
            uptoMessageId: "m-a4",
            summary: "Older summary.",
            tokensBefore: 80,
            tokensAfter: 8,
            createdAt: setup.clock.now(),
            isLive: true
        )
        try await setup.checkpointRepo.save(prior)

        _ = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: prior,
            model: setup.model
        )

        let allCheckpoints = try await setup.checkpointRepo.all(for: setup.conversation.id)
        // Both rows present; only the new one is live.
        #expect(allCheckpoints.count == 2)
        let liveRows = allCheckpoints.filter(\.isLive)
        #expect(liveRows.count == 1)
        #expect(liveRows.first?.id != prior.id)
        let supersededPrior = allCheckpoints.first(where: { $0.id == prior.id })
        #expect(supersededPrior?.isLive == false)
    }

    @Test func compactReturnsNilWhenTooFewMessagesToSummarize() async throws {
        let setup = try await makeSetup(scripts: []) // No script needed — provider must not be called.
        let messageRepo = GRDBMessageRepository(database: setup.database)
        // Three messages — fewer than keepMostRecent + 1 (5).
        for index in 1...3 {
            let row = MessageRecord(
                id: "m\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: "msg \(index)",
                createdAt: setup.clock.now()
            )
            try await messageRepo.save(row)
        }
        let messages = try await messageRepo.fetchAll(conversationId: setup.conversation.id)

        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: nil,
            model: setup.model
        )
        #expect(checkpoint == nil)
        // Provider was never called — no script was enqueued.
        let calls = await setup.provider.capturedRequests()
        #expect(calls.isEmpty)
    }

    @Test func emptySummaryFromProviderThrows() async throws {
        let setup = try await makeSetup(scripts: [
            [
                // Provider yields no text, just messageComplete.
                .messageStart(id: "sum-empty", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 0)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)

        await #expect(throws: CompactorError.self) {
            _ = try await setup.compactor.compact(
                conversationId: setup.conversation.id,
                messages: messages,
                toolCalls: [],
                priorCheckpoint: nil,
                model: setup.model
            )
        }
    }

    @Test func providerErrorEventBubblesAsCompactorLLMError() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-err", model: "fake-model-1"),
                .error(.unauthorized),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)

        do {
            _ = try await setup.compactor.compact(
                conversationId: setup.conversation.id,
                messages: messages,
                toolCalls: [],
                priorCheckpoint: nil,
                model: setup.model
            )
            Issue.record("expected compact to throw, succeeded instead")
        } catch let error as CompactorError {
            switch error {
            case .llmError(let llmError):
                #expect(llmError == .unauthorized)
            default:
                Issue.record("expected .llmError, got \(error)")
            }
        } catch {
            Issue.record("expected CompactorError, got \(error)")
        }
    }

    @Test func stalePriorCheckpointFallsBackToFullHistory() async throws {
        // Regression: a `priorCheckpoint` whose `uptoMessageId` isn't in
        // the message list (deleted, restored from sync, etc.) used to
        // make the pre-flight no-op forever. Compactor falls back to
        // summarizing the full list — and `wouldCompact` must agree.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-stale", model: "fake-model-1"),
                .textDelta(index: 0, text: "Recovered summary."),
                .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 2)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)
        let stale = CompactionCheckpointRecord(
            id: "ck-stale",
            conversationId: setup.conversation.id,
            uptoMessageId: "m-vanished",
            summary: "Lost summary.",
            tokensBefore: 40,
            tokensAfter: 4,
            createdAt: setup.clock.now(),
            isLive: true
        )

        // Predicate must agree with the full-fallback behavior.
        #expect(setup.compactor.wouldCompact(messages: messages, priorCheckpoint: stale))

        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: stale,
            model: setup.model
        )
        #expect(checkpoint != nil)
    }

    @Test func keepMostRecentBoundaryProducesExactlyOneSummarizedMessage() async throws {
        // Tight boundary: with `keepMostRecent = 2` and exactly 3 messages
        // (and no prior checkpoint), the compactor should produce a
        // checkpoint whose `uptoMessageId` is the very first message — a
        // single summarized row, with the trailing two kept verbatim.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-bound", model: "fake-model-1"),
                .textDelta(index: 0, text: "boundary summary"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 2)),
            ],
        ])
        let messageRepo = GRDBMessageRepository(database: setup.database)
        let rows = (1...3).map { index in
            MessageRecord(
                id: "b\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: "msg \(index)",
                createdAt: setup.clock.now()
            )
        }
        for row in rows { try await messageRepo.save(row) }
        let messages = try await messageRepo.fetchAll(conversationId: setup.conversation.id)

        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: nil,
            model: setup.model,
            keepMostRecent: 2
        )
        let saved = try #require(checkpoint)
        #expect(saved.uptoMessageId == "b1")

        // Just below the boundary: 2 messages + keepMostRecent = 2 →
        // nothing to summarize.
        #expect(setup.compactor.wouldCompact(
            messages: Array(messages.prefix(2)),
            priorCheckpoint: nil,
            keepMostRecent: 2
        ) == false)
    }

    @Test func summarizationPromptCarriesPriorSummaryWhenPresent() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-3", model: "fake-model-1"),
                .textDelta(index: 0, text: "Combined summary."),
                .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 2)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)
        let prior = CompactionCheckpointRecord(
            id: "ck-prior",
            conversationId: setup.conversation.id,
            uptoMessageId: "m-a3",
            summary: "Previously: discussed travel plans.",
            tokensBefore: 70,
            tokensAfter: 7,
            createdAt: setup.clock.now(),
            isLive: true
        )
        try await setup.checkpointRepo.save(prior)

        _ = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: prior,
            model: setup.model
        )

        let captured = await setup.provider.capturedRequests()
        let firstRequest = try #require(captured.first)
        // The summarization prompt should have a system message
        // containing the prior summary verbatim, so the new summary
        // subsumes it.
        let containsPrior = firstRequest.messages.contains { msg in
            guard msg.role == .system else { return false }
            if case .text(let text) = msg.content.first {
                return text.contains("Previously: discussed travel plans.")
            }
            return false
        }
        #expect(containsPrior)
    }

    // MARK: - Tool-pair-aware cut

    private func makeRow(
        id: String,
        role: MessageRole,
        offset: TimeInterval,
        toolCallId: String? = nil
    ) -> MessageRecord {
        MessageRecord(
            id: id,
            conversationId: "conv-1",
            role: role,
            content: "content \(id)",
            toolCallId: toolCallId,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset)
        )
    }

    /// The count-based cut must never split an assistant `tool_use` from
    /// its role-`.tool` result rows. The cut snaps *backward* to the
    /// nearest user row, so the whole round-trip — issuer, results, and
    /// the user turn that prompted them — stays verbatim in the kept
    /// tail. (Snapping forward — PR-1's original rule — could consume the
    /// entire kept tail on a wide parallel batch, leaving a follow-up
    /// request with no non-system messages, which Anthropic rejects; and
    /// any non-user kept-window opener trips Anthropic's
    /// first-message-must-be-user rule.)
    @Test func summarizeCutSnapsBackToUserTurnBeforeSplitPair() {
        // 6 rows; keepMostRecent = 2 puts the raw cut on the first result
        // row of a two-call batch — splitting the pair.
        let rows = [
            makeRow(id: "m1", role: .user, offset: 0),
            makeRow(id: "m2", role: .assistant, offset: 1),
            makeRow(id: "m3", role: .user, offset: 2),
            makeRow(id: "m4", role: .assistant, offset: 3),          // issues tc-1, tc-2
            makeRow(id: "m5", role: .tool, offset: 4, toolCallId: "tc-1"),
            makeRow(id: "m6", role: .tool, offset: 5, toolCallId: "tc-2"),
        ]

        let slice = Compactor.messagesToSummarize(
            messages: rows, priorCheckpoint: nil, keepMostRecent: 2
        )

        // The cut walked back past m5 and the issuing assistant row m4 to
        // the user row m3 — the kept tail is [m3, m4, m5, m6], the whole
        // turn intact and user-first.
        #expect(slice.map(\.id) == ["m1", "m2"])
    }

    /// A 4-parallel-call batch at the boundary must not empty the kept
    /// tail: the backward snap lands on the user turn that prompted the
    /// batch and keeps the whole exchange verbatim. (Forward extension
    /// would walk to the end of history here — kept tail empty, follow-up
    /// request with zero non-system messages.)
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

        // Kept tail = [m3, m4, m5...m8]: the prompting user turn, the
        // issuer, and all four results.
        #expect(slice.map(\.id) == ["m1", "m2"])
    }

    /// When no user row exists at or before the cut (here: the
    /// post-checkpoint window *opens* with a pair group the cut lands
    /// inside), the backward walk reaches index 0 — nothing can be
    /// summarized without splitting the pair or stranding an
    /// assistant-first kept window, so the slice is empty and
    /// `wouldCompact` agrees (silent no-op, resolved once later turns add
    /// a user boundary inside the cut).
    @Test func summarizeCutInsideLeadingPairGroupIsANoOp() throws {
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
            checkpointRepository: GRDBCompactionCheckpointRepository(
                database: try ChatDatabase.makeInMemory()
            )
        )
        #expect(!compactor.wouldCompact(messages: rows, priorCheckpoint: nil, keepMostRecent: 2))
    }

    /// A cut landing on a clean turn boundary stays count-based — the
    /// extension only fires when the kept tail would start with result rows.
    @Test func summarizeCutOnTurnBoundaryIsUnchanged() {
        let rows = [
            makeRow(id: "m1", role: .user, offset: 0),
            makeRow(id: "m2", role: .assistant, offset: 1),
            makeRow(id: "m3", role: .tool, offset: 2, toolCallId: "tc-1"),
            makeRow(id: "m4", role: .user, offset: 3),
            makeRow(id: "m5", role: .assistant, offset: 4),
        ]

        let slice = Compactor.messagesToSummarize(
            messages: rows, priorCheckpoint: nil, keepMostRecent: 2
        )

        #expect(slice.map(\.id) == ["m1", "m2", "m3"])
    }

    /// End-to-end: compacting a history whose raw cut splits a tool pair
    /// keeps the whole round-trip verbatim in the kept tail — the
    /// summarization request carries no tool blocks at all, and the
    /// checkpoint lands just before the user turn that prompted the pair
    /// so the post-checkpoint window opens user-first.
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
            makeRow(id: "m2", role: .assistant, offset: 1),
            makeRow(id: "m3", role: .user, offset: 2),
            makeRow(id: "m4", role: .assistant, offset: 3),          // issues tc-1
            makeRow(id: "m5", role: .tool, offset: 4, toolCallId: "tc-1"),
            makeRow(id: "m6", role: .user, offset: 5),
        ]
        for row in rows {
            try await messageRepo.save(row)
        }
        let call = ToolCallRecord(
            id: "tc-1", messageId: "m4", conversationId: setup.conversation.id,
            toolName: "test.lookup", parameters: "{}",
            result: "{\"value\":42}", status: .success,
            createdAt: rows[3].createdAt, completedAt: rows[4].createdAt, signature: nil
        )
        try await toolCallRepo.save(call)

        // keepMostRecent = 2 → raw cut lands on m5 (the result row); the
        // pair-aware cut walks back past the issuer m4 to the user row m3.
        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: rows,
            toolCalls: [call],
            priorCheckpoint: nil,
            model: setup.model,
            keepMostRecent: 2
        )

        #expect(checkpoint?.uptoMessageId == "m2")

        // The summarization request saw only m1 + m2 — no tool blocks,
        // real or synthesized.
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
        #expect(projectedTexts.contains { $0.contains("content m2") })
        #expect(!projectedTexts.contains { $0.contains("content m3") })
        #expect(!projectedTexts.contains { $0.contains("content m4") })
    }

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
        // The *real* result rode along — no synthesized "interrupted" claim.
        #expect(resultContents == ["content m3"])
    }
}
