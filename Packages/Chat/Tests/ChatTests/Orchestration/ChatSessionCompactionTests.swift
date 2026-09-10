import Core
import Foundation
import Testing

@testable import Chat

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
            // Only schema size matters here; these tools are never executed.
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
                [
                    .messageStart(id: "sum", model: "tiny-model"),
                    .textDelta(index: 0, text: "Concise summary of the older turns."),
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
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

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

        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live != nil)

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)
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
        // Schemas consume the fixed floor even when history is unchanged. Use bible.lookup:
        // compact-tier policy retains it, whereas a dropped tool cannot prove the budget change.
        // This seed falls below the 0.5 threshold without the schema and above it with the schema.
        let verboseTool = LLMTool(
            id: "bible.lookup",
            name: "bible.lookup",
            description: String(repeating: "Look up the exact text of a Bible passage. ", count: 100),
            category: .query,
            parameters: [
                LLMToolParameter(
                    name: "reference", type: .string,
                    description: "Passage reference to read.",
                    enumValues: ["book", "chapter", "verse"]
                ),
                LLMToolParameter(name: "translation", type: .string, description: "Optional translation code."),
            ],
            appletId: "bible"
        )
        let model = LLMModel(
            id: "afm", displayName: "AFM", supportsThinking: false,
            supportsTools: true, maxContextTokens: 4_096
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

        func seedTippingHistory(setup: Setup) async throws {
            for index in 1...3 {
                try await setup.messageRepo.save(MessageRecord(
                    id: "tip-u\(index)",
                    conversationId: setup.conversation.id,
                    role: .user,
                    content: String(repeating: "tell me about verse ", count: 28),
                    createdAt: setup.clock.now()
                ))
                try await setup.messageRepo.save(MessageRecord(
                    id: "tip-a\(index)",
                    conversationId: setup.conversation.id,
                    role: .assistant,
                    content: String(repeating: "the passage teaches ", count: 28),
                    createdAt: setup.clock.now()
                ))
            }
        }

        let bare = try await makeSetup(
            scripts: [finalTurn],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.5,
            model: model,
            conversationId: "conv-bare"
        )
        try await seedTippingHistory(setup: bare)
        let bareEvents = await collect(await bare.session.send(text: "next prompt", model: model))
        await bare.session.waitUntilFinished()
        #expect(firedCompaction(bareEvents) == false)
        let bareCheckpoint = try await bare.checkpointRepo.liveCheckpoint(for: bare.conversation.id)
        #expect(bareCheckpoint == nil)

        let withTool = try await makeSetup(
            scripts: [summaryTurn, finalTurn],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.5,
            model: model,
            conversationId: "conv-tool",
            tools: [verboseTool]
        )
        try await seedTippingHistory(setup: withTool)
        let toolEvents = await collect(await withTool.session.send(text: "next prompt", model: model))
        await withTool.session.waitUntilFinished()
        #expect(firedCompaction(toolEvents) == true)
        let toolCheckpoint = try await withTool.checkpointRepo.liveCheckpoint(for: withTool.conversation.id)
        #expect(toolCheckpoint != nil)
    }

    @Test func compactTierCapsAutoCompactThreshold() async throws {
        // This history falls between the compact-tier cap and the looser user threshold.
        // A full-tier model has no cap and must leave the same history uncompacted.
        let summaryTurn: [LLMStreamEvent] = [
            .messageStart(id: "sum-cap", model: "afm"),
            .textDelta(index: 0, text: "Concise summary of the older turns."),
            .messageComplete(usage: TokenUsage(inputTokens: 40, outputTokens: 6)),
        ]
        let finalTurn: [LLMStreamEvent] = [
            .messageStart(id: "m-cap", model: "afm"),
            .textDelta(index: 0, text: "ok"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ]
        let compactModel = LLMModel(
            id: "afm", displayName: "AFM", supportsThinking: false,
            supportsTools: true, maxContextTokens: 4_096
        )

        func seedHeavyHistory(setup: Setup) async throws {
            for index in 1...6 {
                try await setup.messageRepo.save(MessageRecord(
                    id: "cap-u\(index)",
                    conversationId: setup.conversation.id,
                    role: .user,
                    content: String(repeating: "lorem ipsum ", count: 67),
                    createdAt: setup.clock.now()
                ))
                try await setup.messageRepo.save(MessageRecord(
                    id: "cap-a\(index)",
                    conversationId: setup.conversation.id,
                    role: .assistant,
                    content: String(repeating: "dolor sit amet ", count: 53),
                    createdAt: setup.clock.now()
                ))
            }
        }

        let capped = try await makeSetup(
            scripts: [summaryTurn, finalTurn],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.99,
            model: compactModel,
            conversationId: "conv-cap"
        )
        try await seedHeavyHistory(setup: capped)
        let cappedEvents = await collect(await capped.session.send(text: "next", model: compactModel))
        await capped.session.waitUntilFinished()
        #expect(firedCompaction(cappedEvents) == true)

        let uncapped = try await makeSetup(
            scripts: [finalTurn],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.99,
            model: makeBigModel(),
            conversationId: "conv-cap-full"
        )
        try await seedHeavyHistory(setup: uncapped)
        let uncappedEvents = await collect(
            await uncapped.session.send(text: "next", model: uncapped.model)
        )
        await uncapped.session.waitUntilFinished()
        #expect(firedCompaction(uncappedEvents) == false)
    }

    @Test func compactTierDoesNotRecompactEveryTurnOnceHistoryIsSummarized() async throws {
        // The fixed floor survives checkpoints. Gating on total usage would compact
        // every turn; gating on compressible history must settle after one checkpoint.
        let summaryTurn: [LLMStreamEvent] = [
            .messageStart(id: "sum-once", model: "afm"),
            .textDelta(index: 0, text: "Concise summary of the older turns."),
            .messageComplete(usage: TokenUsage(inputTokens: 40, outputTokens: 6)),
        ]
        func assistantTurn(_ id: String) -> [LLMStreamEvent] {
            [
                .messageStart(id: id, model: "afm"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ]
        }
        let compactModel = LLMModel(
            id: "afm", displayName: "AFM", supportsThinking: false,
            supportsTools: true, maxContextTokens: 4_096
        )
        let setup = try await makeSetup(
            scripts: [summaryTurn, assistantTurn("m-first"), assistantTurn("m-second")],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.99,
            model: compactModel,
            conversationId: "conv-once"
        )
        for index in 1...6 {
            try await setup.messageRepo.save(MessageRecord(
                id: "once-u\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: String(repeating: "lorem ipsum ", count: 67),
                createdAt: setup.clock.now()
            ))
            try await setup.messageRepo.save(MessageRecord(
                id: "once-a\(index)",
                conversationId: setup.conversation.id,
                role: .assistant,
                content: String(repeating: "dolor sit amet ", count: 53),
                createdAt: setup.clock.now()
            ))
        }

        let firstEvents = await collect(await setup.session.send(text: "next", model: compactModel))
        await setup.session.waitUntilFinished()
        #expect(firedCompaction(firstEvents) == true)

        let secondEvents = await collect(await setup.session.send(text: "again", model: compactModel))
        await setup.session.waitUntilFinished()
        #expect(firedCompaction(secondEvents) == false)
    }

    @Test func autoCompactionEmptySummaryDuringSendBroadcastsCuratedError() async throws {
        // Auto-compaction must use the same curated error mapping as manual /compact.
        let setup = try await makeSetup(
            scripts: [
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

        guard case .error(let llmError) = events.last else {
            Issue.record("expected trailing .error, got \(String(describing: events.last))")
            return
        }
        guard case .requestFailed(let message) = llmError else {
            Issue.record("expected .requestFailed mapping, got \(llmError)")
            return
        }
        #expect(message == "compaction returned empty summary")

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.allSatisfy { $0.role != .assistant || $0.id.hasPrefix("h-a") })
    }

    @Test func disablingAutoCompactionSuppressesItEvenAboveThreshold() async throws {
        let setup = try await makeSetup(
            scripts: [
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

        let hasCompactionEvent = events.contains { event in
            switch event {
            case .compactionStarted, .compactionCompleted: return true
            default: return false
            }
        }
        #expect(hasCompactionEvent == false)

        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live == nil)

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 1)
    }

    @Test func manualCompactWorksAtAnyUsageLevel() async throws {
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

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let manualUserCount = stored.filter { $0.role == .user && $0.content == "/compact" }.count
        #expect(manualUserCount == 0)

        let started = events.contains { if case .compactionStarted = $0 { return true } else { return false } }
        let completed = events.contains { if case .compactionCompleted = $0 { return true } else { return false } }
        #expect(started)
        #expect(completed)

        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live != nil)
    }

    @Test func manualCompactBelowMinThresholdEmitsUserFacingError() async throws {
        let setup = try await makeSetup(
            scripts: [],
            autoCompactEnabled: false,
            manualCompactMinThreshold: 0.30,
            model: makeBigModel()
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

        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live == nil)
    }

    @Test func manualCompactBelowMinThresholdErrorsOnCompactTierToo() async throws {
        // A compact-tier fixed floor alone must not satisfy the manual compaction gate.
        let setup = try await makeSetup(
            scripts: [],
            autoCompactEnabled: false,
            manualCompactMinThreshold: 0.30,
            model: LLMModel(
                id: "afm", displayName: "AFM", supportsThinking: false,
                supportsTools: true, maxContextTokens: 4_096
            )
        )

        let stream = await setup.session.send(text: "/compact", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case let .error(.requestFailed(message)) = events.first else {
            Issue.record("expected .error(.requestFailed) on a near-empty compact-tier /compact, got \(events)")
            return
        }
        #expect(message.contains("too short"))
        let calls = await setup.provider.capturedRequests()
        #expect(calls.isEmpty)
    }

    @Test func manualCompactSummarizesEntireHistory() async throws {
        // Manual compaction keeps no raw tail, anchoring the banner at the last stored row.
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
        // keepMostRecent is a floor: snapping the boundary to a user turn may retain
        // extra rows. The newly saved user prompt is included, but its reply is not.
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

        let userTurnIndex = try #require(storedAfter.firstIndex(where: { $0.content == "next prompt" }))
        let rawCutIndex = (userTurnIndex + 1) - Compactor.defaultKeepMostRecent
        #expect(storedAfter[rawCutIndex].id == "h-a5")
        #expect(checkpoint.uptoMessageId == "h-a4")
        let cutoffIndex = try #require(storedAfter.firstIndex(where: { $0.id == checkpoint.uptoMessageId }))
        #expect(storedAfter[cutoffIndex + 1].role == .user)
    }

    @Test func autoCompactDoesNotFireMidToolLoopWhenStillUnderThreshold() async throws {
        // The budget is checked each tool-loop iteration; a small result must not
        // introduce a spurious mid-loop compaction.
        let toolID = "test.smallBlob"
        let setup = try await makeSetup(
            scripts: [
                [
                    .messageStart(id: "m1", model: "tiny-model"),
                    .toolUse(index: 0, id: "tc-1", name: toolID, input: .object([:]), signature: nil),
                    .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
                ],
                [
                    .messageStart(id: "m2", model: "tiny-model"),
                    .textDelta(index: 0, text: "ok"),
                    .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
                ],
            ],
            autoCompactEnabled: true,
            autoCompactThreshold: 0.99,
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

        // Either session may consume the first script; checkpoint writes must remain independent.
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

        let liveA = try await checkpointRepo.liveCheckpoint(for: "conv-A")
        let liveB = try await checkpointRepo.liveCheckpoint(for: "conv-B")
        #expect(liveA != nil)
        #expect(liveB != nil)
        #expect(liveA?.id != liveB?.id)
    }
}
