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
            case .modelResolved: return "modelResolved"
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
        //
        // The tool here is `bible.lookup` — the grounding tool AFM still ships
        // on the compact tier (CompactToolPolicy keeps lookup + memory). A
        // *dropped* tool like `bible.annotate` would no longer count toward a
        // small-window model's budget, so it can't be used to prove this.
        //
        // Arithmetic at the AFM-realistic 4096 window (compact tier gates the
        // compressible history against the window left after the fixed
        // floor): history ≈ 830 tokens in both arms. Bare arm floor = the
        // 800-token allowance → 830/3,296 ≈ 0.25, under the 0.5 threshold.
        // Tool arm floor = allowance + the ~1.1k-token raw schema inflated
        // ×1.8 ≈ 2,795 → 830/1,301 ≈ 0.64 — the schema shrinks the available
        // window until the same history must compact.
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

        // ~830 tokens of history (6 × ~550 chars) — the tipping mass.
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

        // Arm 1 — no tools registered → history over the bare available
        // window is under 0.5 → no compaction (only the assistant turn
        // streams).
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

        // Arm 2 — same history, but the verbose tool is registered → its
        // schema shrinks the available window, pushing the history ratio
        // over 0.5 → compaction fires first.
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
        // Small-window models compact at min(userThreshold,
        // ChatSettings.compactTierAutoCompactThreshold), gated on the
        // compressible slice: with the user's threshold at a loose 0.99,
        // ≈2.4k history tokens over the 3,296 left after the 800-token
        // allowance reads ≈0.73 — over the 0.6 cap, under the user value —
        // so the 4096-window model must compact, while the same history +
        // threshold on a full-tier model must not (no cap; the total ratio
        // is tiny on 100k anyway).
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
            // 12 × ~800 chars ≈ 2.4k tokens — its compressible ratio sits
            // between the 0.6 cap and the 0.99 user threshold on a 4096
            // window, and there are enough rows beyond keepMostRecent for
            // the compactor.
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
        // The compact tier's fixed floor (allowance + briefings + tools)
        // survives every checkpoint. A gate on the *total* ratio would
        // therefore stay over threshold forever once the floor is close to
        // it — re-firing compaction (an extra on-device round-trip + a
        // banner flash) on every single turn. The compressible gate must go
        // quiet after one compaction: the summarized history is far below
        // the cap even though the total never drops.
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
        // Same ~2.4k-token seed as the cap test — over the 0.6 cap.
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
        // Full-tier window: on the compact tier the calibration allowance
        // alone would push a tiny window past the gate.
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

        // No checkpoint persisted.
        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live == nil)
    }

    @Test func manualCompactBelowMinThresholdErrorsOnCompactTierToo() async throws {
        // The compact tier's fixed floor (the 800-token allowance, plus
        // briefings/tools when present) must NOT satisfy the manual gate by
        // itself — the gate reads the compressible slice there, so a
        // near-empty AFM-window conversation still gets the "too short"
        // error instead of summarizing a single message.
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
        // fires *before* the assistant reply persists, so the raw cut
        // excludes the trailing 4, landing on h-a5 (index 9); the
        // user-turn-boundary snap then walks back one row so the kept
        // window opens at h-u5 → checkpoint.uptoMessageId is h-a4
        // (index 7). The kept tail is one row wider than the raw count —
        // `defaultKeepMostRecent` is a floor, not an exact width.
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
        // The raw cut (count - defaultKeepMostRecent, counting the 13 rows
        // the compactor saw) lands on the assistant row h-a5; the snap
        // opens the kept window one row earlier, on the user row h-u5.
        let userTurnIndex = try #require(storedAfter.firstIndex(where: { $0.content == "next prompt" }))
        let rawCutIndex = (userTurnIndex + 1) - Compactor.defaultKeepMostRecent
        #expect(storedAfter[rawCutIndex].id == "h-a5")
        #expect(checkpoint.uptoMessageId == "h-a4")
        // The first kept row is the user turn just after the cutoff.
        let cutoffIndex = try #require(storedAfter.firstIndex(where: { $0.id == checkpoint.uptoMessageId }))
        #expect(storedAfter[cutoffIndex + 1].role == .user)
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
