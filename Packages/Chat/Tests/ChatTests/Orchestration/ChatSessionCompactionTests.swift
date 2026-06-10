import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ChatSession`'s compaction integration: auto-compaction
/// fires before a turn when over threshold, the auto toggle suppresses
/// it, manual `/compact` works at any usage level, and concurrent
/// sessions don't race on the checkpoint table.
@Suite("ChatSession compaction")
struct ChatSessionCompactionTests {

    private struct Setup {
        let database: ChatDatabase
        let messageRepo: GRDBMessageRepository
        let toolCallRepo: GRDBToolCallRepository
        let checkpointRepo: GRDBCompactionCheckpointRepository
        let conversationRepo: GRDBConversationRepository
        let llmRegistry: LLMProviderRegistry
        let provider: FakeLLMProvider
        let conversation: ConversationRecord
        let model: LLMModel
        let session: ChatSession
        let clock: FixedClock
    }

    /// Tiny model context window so a few short messages already overflow
    /// any threshold ≥ ~1%. Keeps the auto-compact tests cheap to seed.
    private func makeTinyModel() -> LLMModel {
        LLMModel(
            id: "tiny-model",
            displayName: "Tiny",
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: 50
        )
    }

    private func makeBigModel() -> LLMModel {
        LLMModel(
            id: "big-model",
            displayName: "Big",
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: 100_000
        )
    }

    private func makeSetup(
        scripts: [[LLMStreamEvent]] = [],
        autoCompactEnabled: Bool = true,
        autoCompactThreshold: Double = 0.75,
        manualCompactMinThreshold: Double = 0.0,
        model: LLMModel? = nil,
        conversationId: String = "conv-1",
        tools: [LLMTool] = []
    ) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let conversationRepo = GRDBConversationRepository(database: database)
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let resolvedModel = model ?? makeTinyModel()
        let provider = FakeLLMProvider(model: resolvedModel)
        for script in scripts { await provider.enqueue(script) }
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let toolRegistry = ToolRegistry()
        for tool in tools {
            // The assistant scripts never call these — they exist only so
            // `enabledTools()` reports their schemas to the budget meter — so a
            // throwaway executor suffices.
            let executor = FakeToolExecutor(toolID: tool.id)
            await executor.setResult(ToolResult(toolID: tool.id, content: "", isError: false))
            await toolRegistry.register(ToolRegistration(tool: tool, execution: .local(executor)))
        }
        let compactor = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGen
        )
        let conversation = try await OrchestrationFixtures.seedConversation(
            in: database, id: conversationId, clock: clock
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
            autoCompactEnabled: autoCompactEnabled,
            autoCompactThreshold: autoCompactThreshold,
            manualCompactMinThreshold: manualCompactMinThreshold
        )
        return Setup(
            database: database,
            messageRepo: messageRepo,
            toolCallRepo: toolCallRepo,
            checkpointRepo: checkpointRepo,
            conversationRepo: conversationRepo,
            llmRegistry: llmRegistry,
            provider: provider,
            conversation: conversation,
            model: resolvedModel,
            session: session,
            clock: clock
        )
    }

    private func seedSummarizableHistory(setup: Setup) async throws {
        // 12 messages total — leaves 8 to summarize once we keep the
        // default 4 most-recent verbatim.
        for index in 1...6 {
            try await setup.messageRepo.save(MessageRecord(
                id: "h-u\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: "user message \(index) with some words",
                createdAt: setup.clock.now()
            ))
            try await setup.messageRepo.save(MessageRecord(
                id: "h-a\(index)",
                conversationId: setup.conversation.id,
                role: .assistant,
                content: "assistant reply \(index) with some words",
                createdAt: setup.clock.now()
            ))
        }
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func autoCompactionFiresWhenAssemblyExceedsThreshold() async throws {
        let setup = try await makeSetup(
            scripts: [
                // Summarization turn (compactor).
                [
                    .messageStart(id: "sum", model: "tiny-model"),
                    .textDelta(index: 0, text: "Concise summary of the older turns."),
                    .messageComplete(usage: TokenUsage(inputTokens: 80, outputTokens: 8)),
                ],
                // The actual assistant turn.
                [
                    .messageStart(id: "m-final", model: "tiny-model"),
                    .textDelta(index: 0, text: "ok"),
                    .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
                ],
            ],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.5
        )
        try await seedSummarizableHistory(setup: setup)

        let stream = await setup.session.send(text: "next prompt", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // Compaction events fired in order, before the assistant save.
        let kinds = events.map { event -> String in
            switch event {
            case .userMessageSaved: return "user"
            case .textDelta: return "text"
            case .thinkingDelta: return "thinking"
            case .toolCallStarted: return "toolStarted"
            case .toolCallAwaitingConfirmation: return "toolAwaitingConfirmation"
            case .toolCallCompleted: return "toolCompleted"
            case .toolCallFailed: return "toolFailed"
            case .assistantMessageSaved: return "assistantSaved"
            case .compactionStarted: return "compactionStarted"
            case .compactionCompleted: return "compactionCompleted"
            case .error: return "error"
            }
        }
        let startedIndex = kinds.firstIndex(of: "compactionStarted")
        let completedIndex = kinds.firstIndex(of: "compactionCompleted")
        let assistantIndex = kinds.firstIndex(of: "assistantSaved")
        let started = try #require(startedIndex)
        let completed = try #require(completedIndex)
        let assistant = try #require(assistantIndex)
        #expect(started < completed)
        #expect(completed < assistant)

        // A live checkpoint exists in the DB now.
        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live != nil)

        // Two LLM stream calls were issued: summarization, then turn.
        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)
    }

    private func seedShortHistory(setup: Setup) async throws {
        // Deliberately tiny: a handful of words so the message-only token
        // estimate sits far below any sane threshold. The tool schemas are
        // what move the needle in the regression below.
        for index in 1...3 {
            try await setup.messageRepo.save(MessageRecord(
                id: "s-u\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: "msg \(index)",
                createdAt: setup.clock.now()
            ))
            try await setup.messageRepo.save(MessageRecord(
                id: "s-a\(index)",
                conversationId: setup.conversation.id,
                role: .assistant,
                content: "reply \(index)",
                createdAt: setup.clock.now()
            ))
        }
    }

    private func firedCompaction(_ events: [ChatEvent]) -> Bool {
        events.contains { event in
            switch event {
            case .compactionStarted, .compactionCompleted: return true
            default: return false
            }
        }
    }

    @Test func toolSchemasTipBorderlineConversationIntoAutoCompaction() async throws {
        // Regression for the AFM silent-overflow: a conversation that reads as
        // *under* the auto-compact threshold when only messages are counted
        // must tip *over* once the verbose tool schemas it actually ships are
        // folded into the budget — so compaction fires before the on-device
        // window overflows. Identical history + model + threshold in both
        // arms; the only variable is whether a tool is registered.
        //
        // Before the fix `estimate(messages:)` ignored tool definitions, so
        // both arms read identically under-threshold and the tool arm never
        // compacted → AFM then overflowed mid-turn.
        let verboseTool = LLMTool(
            id: "bible.annotate",
            name: "bible.annotate",
            description: String(repeating: "Create a study annotation for a passage. ", count: 40),
            category: .mutation,
            parameters: [
                LLMToolParameter(
                    name: "target", type: .string,
                    description: "Scripture unit to annotate.",
                    enumValues: ["book", "chapter", "verse"]
                ),
                LLMToolParameter(name: "body", type: .string, description: "The annotation body text."),
            ],
            appletId: "bible"
        )
        // Window sized so the short history is ~3% full, but the tool schema
        // (~400 tokens) alone overruns it.
        let model = LLMModel(
            id: "afm", displayName: "AFM", supportsThinking: false,
            supportsTools: true, maxContextTokens: 300
        )
        let finalTurn: [LLMStreamEvent] = [
            .messageStart(id: "m-final", model: "afm"),
            .textDelta(index: 0, text: "ok"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ]
        let summaryTurn: [LLMStreamEvent] = [
            .messageStart(id: "sum", model: "afm"),
            .textDelta(index: 0, text: "Concise summary of the older turns."),
            .messageComplete(usage: TokenUsage(inputTokens: 40, outputTokens: 6)),
        ]

        // Arm 1 — no tools registered → message-only budget is under 0.5 → no
        // compaction (only the assistant turn streams).
        let bare = try await makeSetup(
            scripts: [finalTurn],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.5,
            model: model,
            conversationId: "conv-bare"
        )
        try await seedShortHistory(setup: bare)
        let bareEvents = await collect(await bare.session.send(text: "next prompt", model: model))
        await bare.session.waitUntilFinished()
        #expect(firedCompaction(bareEvents) == false)
        let bareCheckpoint = try await bare.checkpointRepo.liveCheckpoint(for: bare.conversation.id)
        #expect(bareCheckpoint == nil)

        // Arm 2 — same history, but the verbose tool is registered → its
        // schema pushes the budget over 0.5 → compaction fires first.
        let withTool = try await makeSetup(
            scripts: [summaryTurn, finalTurn],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.5,
            model: model,
            conversationId: "conv-tool",
            tools: [verboseTool]
        )
        try await seedShortHistory(setup: withTool)
        let toolEvents = await collect(await withTool.session.send(text: "next prompt", model: model))
        await withTool.session.waitUntilFinished()
        #expect(firedCompaction(toolEvents) == true)
        let toolCheckpoint = try await withTool.checkpointRepo.liveCheckpoint(for: withTool.conversation.id)
        #expect(toolCheckpoint != nil)
    }

    @Test func autoCompactionEmptySummaryDuringSendBroadcastsCuratedError() async throws {
        // Regression for the PR #73 round-2 fix: `runGuardedTurn` adds a
        // `CompactorError` arm so an auto-compaction failure during the
        // send/retry path uses the same curated copy as manual /compact,
        // instead of falling through to `.requestFailed(localizedDescription)`
        // which would surface "The operation couldn't be completed" style
        // raw Swift errors. Script the summarization turn to emit no text
        // → empty summary → `CompactorError.emptySummary` → assert the
        // session broadcasts the curated string.
        let setup = try await makeSetup(
            scripts: [
                // Summarization turn — completes with zero text, so the
                // Compactor throws `.emptySummary`.
                [
                    .messageStart(id: "sum", model: "tiny-model"),
                    .messageComplete(usage: TokenUsage(inputTokens: 80, outputTokens: 0)),
                ],
            ],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.5
        )
        try await seedSummarizableHistory(setup: setup)

        let stream = await setup.session.send(text: "next prompt", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // The terminal event is the curated CompactorError mapping, not
        // a generic `.requestFailed(localizedDescription)`.
        guard case .error(let llmError) = events.last else {
            Issue.record("expected trailing .error, got \(String(describing: events.last))")
            return
        }
        guard case .requestFailed(let message) = llmError else {
            Issue.record("expected .requestFailed mapping, got \(llmError)")
            return
        }
        #expect(message == "compaction returned empty summary")

        // No assistant row was persisted — the failure happened before
        // the LLM turn could run.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.allSatisfy { $0.role != .assistant || $0.id.hasPrefix("h-a") })
    }

    @Test func disablingAutoCompactionSuppressesItEvenAboveThreshold() async throws {
        let setup = try await makeSetup(
            scripts: [
                // Only the assistant turn — compactor must NOT be called.
                [
                    .messageStart(id: "m-final", model: "tiny-model"),
                    .textDelta(index: 0, text: "ok"),
                    .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
                ],
            ],
            autoCompactEnabled: false,
            autoCompactThreshold: 0.5
        )
        try await seedSummarizableHistory(setup: setup)

        let stream = await setup.session.send(text: "next prompt", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // No compaction events.
        let hasCompactionEvent = events.contains { event in
            switch event {
            case .compactionStarted, .compactionCompleted: return true
            default: return false
            }
        }
        #expect(hasCompactionEvent == false)

        // No checkpoint in DB.
        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live == nil)

        // Provider only called once — for the user turn.
        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 1)
    }

    @Test func manualCompactWorksAtAnyUsageLevel() async throws {
        // Tiny model + autoCompactEnabled = false would normally suppress
        // any compaction, but `/compact` is a manual override so it should
        // run even when the prompt isn't over threshold.
        let setup = try await makeSetup(
            scripts: [
                [
                    .messageStart(id: "sum-manual", model: "big-model"),
                    .textDelta(index: 0, text: "Manual summary."),
                    .messageComplete(usage: TokenUsage(inputTokens: 40, outputTokens: 3)),
                ],
            ],
            autoCompactEnabled: false,
            autoCompactThreshold: 0.99,
            model: makeBigModel()
        )
        try await seedSummarizableHistory(setup: setup)

        let stream = await setup.session.send(text: "/compact", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // Slash command does NOT write a user message.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let manualUserCount = stored.filter { $0.role == .user && $0.content == "/compact" }.count
        #expect(manualUserCount == 0)

        // Compaction events fired.
        let started = events.contains { if case .compactionStarted = $0 { return true } else { return false } }
        let completed = events.contains { if case .compactionCompleted = $0 { return true } else { return false } }
        #expect(started)
        #expect(completed)

        // Checkpoint persisted.
        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live != nil)
    }

    @Test func manualCompactBelowMinThresholdEmitsUserFacingError() async throws {
        // Empty / nearly-empty conversation → ratio is well under the
        // 30% gate → manual /compact must surface a single `.error` event
        // with a user-facing message and never invoke the provider.
        let setup = try await makeSetup(
            scripts: [],
            autoCompactEnabled: false,
            manualCompactMinThreshold: 0.30
        )

        let stream = await setup.session.send(text: "/compact", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        #expect(events.count == 1)
        guard case let .error(.requestFailed(message)) = events.first else {
            Issue.record("expected a single .error(.requestFailed) event, got \(events)")
            return
        }
        #expect(message.contains("30%"))
        #expect(message.contains("too short"))

        let calls = await setup.provider.capturedRequests()
        #expect(calls.isEmpty)

        // No checkpoint persisted.
        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live == nil)
    }

    @Test func manualCompactSummarizesEntireHistory() async throws {
        // Manual /compact uses keepMostRecent=0 — the persisted
        // checkpoint's uptoMessageId must point at the last message on
        // disk so the banner anchors at the bottom of the transcript and
        // the next assistant turn proceeds against the summary alone.
        let setup = try await makeSetup(
            scripts: [
                [
                    .messageStart(id: "sum-manual", model: "tiny-model"),
                    .textDelta(index: 0, text: "Manual summary covers everything."),
                    .messageComplete(usage: TokenUsage(inputTokens: 40, outputTokens: 4)),
                ],
            ],
            autoCompactEnabled: false,
            autoCompactThreshold: 0.99,
            manualCompactMinThreshold: 0.0
        )
        try await seedSummarizableHistory(setup: setup)

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let lastBeforeCompact = try #require(stored.last?.id)

        let stream = await setup.session.send(text: "/compact", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        let checkpoint = try #require(live)
        #expect(checkpoint.uptoMessageId == lastBeforeCompact)
    }

    @Test func autoCompactKeepsTrailingMessagesVerbatim() async throws {
        // Auto-compaction still uses Compactor.defaultKeepMostRecent (4)
        // to preserve immediate-context fidelity for the next turn. Pin
        // the exact slice boundary so a regression that quietly changes
        // `defaultKeepMostRecent` (or auto's pass-through to it) trips
        // here rather than waiting on a flake elsewhere.
        //
        // Layout at compaction time: the seeded 12 messages plus the
        // newly-saved user message under test = 13 rows. The auto path
        // fires *before* the assistant reply persists, so the slice
        // excludes the trailing 4 → checkpoint.uptoMessageId is index
        // (13 - 4 - 1) = index 8 of the pre-turn message list (the user
        // turn the test sends is index 12; the checkpoint cutoff is
        // 5 messages back from the end of the in-prompt window).
        let setup = try await makeSetup(
            scripts: [
                [
                    .messageStart(id: "sum-auto", model: "tiny-model"),
                    .textDelta(index: 0, text: "Auto summary keeps the tail verbatim."),
                    .messageComplete(usage: TokenUsage(inputTokens: 80, outputTokens: 8)),
                ],
                [
                    .messageStart(id: "m-final", model: "tiny-model"),
                    .textDelta(index: 0, text: "ok"),
                    .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
                ],
            ],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.5
        )
        try await seedSummarizableHistory(setup: setup)

        let stream = await setup.session.send(text: "next prompt", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let storedAfter = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        let checkpoint = try #require(live)

        // Find the user turn that triggered compaction; the slice the
        // compactor saw extends from index 0 through that user message
        // (the assistant reply persists later, after compaction runs).
        let userTurnIndex = try #require(storedAfter.firstIndex(where: { $0.content == "next prompt" }))
        let expectedCutoffIndex = userTurnIndex - Compactor.defaultKeepMostRecent
        let expectedCutoffId = storedAfter[expectedCutoffIndex].id
        #expect(checkpoint.uptoMessageId == expectedCutoffId)
    }

    @Test func autoCompactDoesNotFireMidToolLoopWhenStillUnderThreshold() async throws {
        // The orchestrator runs `maybeAutoCompact` at the top of every
        // turn-loop iteration, so a regression that miscalculates per-
        // iteration budget would surface as a spurious mid-loop trigger.
        // This test pins the negative case: small history + small tool
        // result → no compaction event anywhere in the run, even though
        // the loop runs twice.
        let toolID = "test.smallBlob"
        let setup = try await makeSetup(
            scripts: [
                // Iter 1: tool call.
                [
                    .messageStart(id: "m1", model: "tiny-model"),
                    .toolUse(index: 0, id: "tc-1", name: toolID, input: .object([:]), signature: nil),
                    .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
                ],
                // Iter 2: closing assistant text.
                [
                    .messageStart(id: "m2", model: "tiny-model"),
                    .textDelta(index: 0, text: "ok"),
                    .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
                ],
            ],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.99,
            // Big model so even after the tool result we're nowhere near
            // 99% of context.
            model: makeBigModel()
        )

        let toolDef = LLMTool(
            id: toolID, name: toolID, description: "test",
            category: .query, parameters: [], appletId: "test"
        )
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "small", isError: false))
        let toolRegistry = ToolRegistry()
        await toolRegistry.register(ToolRegistration(tool: toolDef, execution: .local(executor)))
        let compactor = OrchestrationFixtures.makeCompactor(
            database: setup.database, llmRegistry: setup.llmRegistry,
            clock: setup.clock, idGenerator: DeterministicIDGenerator(prefix: "loop-", start: 0)
        )
        // Recreate the session against the populated tool registry.
        let session = ChatSession(
            conversationId: setup.conversation.id,
            messageRepository: setup.messageRepo,
            toolCallRepository: setup.toolCallRepo,
            checkpointRepository: setup.checkpointRepo,
            llmProviderRegistry: setup.llmRegistry,
            toolRegistry: toolRegistry,
            compactor: compactor,
            clock: setup.clock,
            idGenerator: DeterministicIDGenerator(prefix: "sess-", start: 0),
            autoCompactEnabled: true,
            autoCompactThreshold: 0.99
        )

        let stream = await session.send(text: "go", model: setup.model)
        let events = await collect(stream)
        await session.waitUntilFinished()

        let toolCompleted = events.contains { if case .toolCallCompleted = $0 { return true } else { return false } }
        let compactionFired = events.contains { event in
            if case .compactionStarted = event { return true }
            if case .compactionCompleted = event { return true }
            return false
        }
        #expect(toolCompleted)
        #expect(compactionFired == false)
    }

    @Test func twoConcurrentSessionsCompactWithoutRacing() async throws {
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let conversationRepo = GRDBConversationRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGenA = DeterministicIDGenerator(prefix: "a-", start: 0)
        let idGenB = DeterministicIDGenerator(prefix: "b-", start: 0)
        let model = makeBigModel()

        // One provider used by both sessions; enqueue two summarization
        // scripts. Either ordering is fine — the actor protecting the
        // checkpoint repo serializes the two writes regardless.
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([
            .messageStart(id: "sum-1", model: "big-model"),
            .textDelta(index: 0, text: "Summary one."),
            .messageComplete(usage: TokenUsage(inputTokens: 20, outputTokens: 2)),
        ])
        await provider.enqueue([
            .messageStart(id: "sum-2", model: "big-model"),
            .textDelta(index: 0, text: "Summary two."),
            .messageComplete(usage: TokenUsage(inputTokens: 20, outputTokens: 2)),
        ])
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let toolRegistry = ToolRegistry()

        try await conversationRepo.save(OrchestrationFixtures.makeConversation(id: "conv-A", clock: clock))
        try await conversationRepo.save(OrchestrationFixtures.makeConversation(id: "conv-B", clock: clock))

        // Seed enough messages on BOTH conversations so manual compact
        // has work to do.
        for conv in ["conv-A", "conv-B"] {
            for index in 1...6 {
                try await messageRepo.save(MessageRecord(
                    id: "\(conv)-u\(index)",
                    conversationId: conv,
                    role: .user,
                    content: "user message \(index)",
                    createdAt: clock.now()
                ))
                try await messageRepo.save(MessageRecord(
                    id: "\(conv)-a\(index)",
                    conversationId: conv,
                    role: .assistant,
                    content: "assistant reply \(index)",
                    createdAt: clock.now()
                ))
            }
        }

        let compactorA = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGenA
        )
        let compactorB = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGenB
        )
        let sessionA = ChatSession(
            conversationId: "conv-A",
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            compactor: compactorA,
            clock: clock,
            idGenerator: idGenA,
            autoCompactEnabled: false,
            manualCompactMinThreshold: 0.0
        )
        let sessionB = ChatSession(
            conversationId: "conv-B",
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            compactor: compactorB,
            clock: clock,
            idGenerator: idGenB,
            autoCompactEnabled: false,
            manualCompactMinThreshold: 0.0
        )

        // Fire `/compact` on both sessions concurrently via a TaskGroup.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let stream = await sessionA.send(text: "/compact", model: model)
                for await _ in stream {}
                await sessionA.waitUntilFinished()
            }
            group.addTask {
                let stream = await sessionB.send(text: "/compact", model: model)
                for await _ in stream {}
                await sessionB.waitUntilFinished()
            }
        }

        // Each conversation has its own live checkpoint — neither raced
        // the other into an inconsistent state.
        let liveA = try await checkpointRepo.liveCheckpoint(for: "conv-A")
        let liveB = try await checkpointRepo.liveCheckpoint(for: "conv-B")
        #expect(liveA != nil)
        #expect(liveB != nil)
        #expect(liveA?.id != liveB?.id)
    }
}
