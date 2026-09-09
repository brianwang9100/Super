import Core
import Foundation
import Testing

@testable import Chat

@Suite("ChatSessionStore")
struct ChatSessionStoreTests {

    private struct StoreSetup {
        let database: ChatDatabase
        let store: ChatSessionStore
        let provider: FakeLLMProvider
        let model: LLMModel
        let toolRegistry: ToolRegistry
        let clock: FixedClock
    }

    private func makeStore(scripts: [[LLMStreamEvent]] = []) async throws -> StoreSetup {
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let conversationRepo = GRDBConversationRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        for script in scripts { await provider.enqueue(script) }
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let toolRegistry = ToolRegistry()
        let compactor = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGen
        )
        let store = ChatSessionStore(
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            compactor: compactor,
            clock: clock,
            idGenerator: idGen,
            autoCompactEnabled: false
        )

        try await conversationRepo.save(OrchestrationFixtures.makeConversation(id: "conv-A", clock: clock))
        try await conversationRepo.save(OrchestrationFixtures.makeConversation(id: "conv-B", clock: clock))

        return StoreSetup(
            database: database,
            store: store,
            provider: provider,
            model: model,
            toolRegistry: toolRegistry,
            clock: clock
        )
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func sessionForReturnsTheSameInstanceOnRepeatedCalls() async throws {
        let setup = try await makeStore()
        let first = await setup.store.session(for: "conv-A")
        let second = await setup.store.session(for: "conv-A")
        #expect(first === second)
    }

    @Test func sessionForCreatesDistinctInstancesPerConversation() async throws {
        let setup = try await makeStore()
        let a = await setup.store.session(for: "conv-A")
        let b = await setup.store.session(for: "conv-B")
        #expect(a !== b)
    }

    @Test func twoSessionsRunInParallelToCompletion() async throws {
        let setup = try await makeStore(scripts: [
            [
                .messageStart(id: "ma", model: "fake-model-1"),
                .textDelta(index: 0, text: "from A"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            [
                .messageStart(id: "mb", model: "fake-model-1"),
                .textDelta(index: 0, text: "from B"),
                .messageComplete(usage: TokenUsage(inputTokens: 2, outputTokens: 2)),
            ],
        ])
        let sessionA = await setup.store.session(for: "conv-A")
        let sessionB = await setup.store.session(for: "conv-B")

        async let eventsA: [ChatEvent] = {
            let stream = await sessionA.send(text: "ping A", model: setup.model)
            return await self.collect(stream)
        }()
        async let eventsB: [ChatEvent] = {
            let stream = await sessionB.send(text: "ping B", model: setup.model)
            return await self.collect(stream)
        }()

        let (a, b) = await (eventsA, eventsB)
        await sessionA.waitUntilFinished()
        await sessionB.waitUntilFinished()

        guard case .assistantMessageSaved = a.last,
              case .assistantMessageSaved = b.last else {
            Issue.record("expected both sessions to finish with assistantMessageSaved; got A=\(String(describing: a.last)), B=\(String(describing: b.last))")
            return
        }
    }

    @Test func cancellingOneSessionDoesNotAffectSiblings() async throws {
        let toolID = "test.sleep"
        let toolDef = LLMTool(
            id: toolID,
            name: "sleep",
            description: "Test tool that sleeps until cancelled.",
            category: .query,
            parameters: [],
            appletId: "test"
        )
        let sleepingExecutor = SleepingToolExecutor(toolID: toolID)

        let setup = try await makeStore(scripts: [
            [
                .messageStart(id: "ma", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-a", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 0)),
            ],
            [
                .messageStart(id: "mb", model: "fake-model-1"),
                .textDelta(index: 0, text: "B done"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])

        await setup.toolRegistry.register(ToolRegistration(tool: toolDef, execution: .local(sleepingExecutor)))

        let sessionA = await setup.store.session(for: "conv-A")
        let sessionB = await setup.store.session(for: "conv-B")

        // Both sessions consume one shared script queue. Wait until A enters its tool
        // before starting B, or B can steal the tool-call script and issue an unscripted turn.
        let streamA = await sessionA.send(text: "kick A", model: setup.model)
        async let eventsA: [ChatEvent] = self.collect(streamA)
        await sleepingExecutor.awaitFirstCall()

        let streamB = await sessionB.send(text: "kick B", model: setup.model)
        async let eventsB: [ChatEvent] = self.collect(streamB)

        await setup.store.cancel(for: "conv-A")

        let (a, b) = await (eventsA, eventsB)
        await sessionA.waitUntilFinished()
        await sessionB.waitUntilFinished()

        guard case .error(let llmError) = a.last else {
            Issue.record("expected A to terminate with .error, got \(String(describing: a.last))")
            return
        }
        #expect(llmError == .cancelled)

        guard case .assistantMessageSaved = b.last else {
            Issue.record("expected B to finish with .assistantMessageSaved, got \(String(describing: b.last))")
            return
        }
    }

    @Test func shutdownCancelsAllAndDropsSessions() async throws {
        let setup = try await makeStore(scripts: [
            [
                .messageStart(id: "ma", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-a", name: "test.shutdown-a", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 0)),
            ],
            [
                .messageStart(id: "mb", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-b", name: "test.shutdown-b", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 0)),
            ],
        ])
        let executorA = SleepingToolExecutor(toolID: "test.shutdown-a")
        let executorB = SleepingToolExecutor(toolID: "test.shutdown-b")
        for executor in [executorA, executorB] {
            let tool = LLMTool(
                id: executor.toolID, name: executor.toolID,
                description: "Waits for cancellation during shutdown.",
                category: .query, parameters: [], appletId: "test"
            )
            await setup.toolRegistry.register(ToolRegistration(tool: tool, execution: .local(executor)))
        }
        let sessionA = await setup.store.session(for: "conv-A")
        let sessionB = await setup.store.session(for: "conv-B")
        let streamA = await sessionA.send(text: "ping A", model: setup.model)
        await executorA.awaitFirstCall()
        let streamB = await sessionB.send(text: "ping B", model: setup.model)
        await executorB.awaitFirstCall()
        #expect(Set(await setup.store.runningConversations()) == ["conv-A", "conv-B"])

        await setup.store.shutdown()
        // Shutdown itself must drain cancellation writes before returning.
        // Do not call waitUntilFinished here and mask a missing drain.
        #expect(await sessionA.isStreaming == false)
        #expect(await sessionB.isStreaming == false)
        let calls = GRDBToolCallRepository(database: setup.database)
        let messages = GRDBMessageRepository(database: setup.database)
        for (conversationID, callID) in [("conv-A", "tc-a"), ("conv-B", "tc-b")] {
            #expect(try await calls.fetch(id: callID)?.status == .cancelled)
            let rows = try await messages.fetchAll(conversationId: conversationID)
            #expect(rows.map(\.role) == [.user, .assistant, .tool])
            #expect(rows.last?.toolCallId == callID)
        }
        #expect(await self.collect(streamA).last == .error(.cancelled))
        #expect(await self.collect(streamB).last == .error(.cancelled))
        #expect(await setup.store.runningConversations().isEmpty)

        let sessionAReborn = await setup.store.session(for: "conv-A")
        let sessionBReborn = await setup.store.session(for: "conv-B")
        #expect(sessionA !== sessionAReborn)
        #expect(sessionB !== sessionBReborn)
    }

    @Test func setUserPersonalizationFansOutToExistingSession() async throws {
        let setup = try await makeStore(scripts: [
            [
                .messageStart(id: "ma", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let sessionA = await setup.store.session(for: "conv-A")

        await setup.store.setUserPersonalization("Always answer in haiku.")

        let stream = await sessionA.send(text: "hi", model: setup.model)
        _ = await self.collect(stream)
        await sessionA.waitUntilFinished()

        let request = await setup.provider.capturedRequests().last
        #expect(request?.messages.first?.role == .system)
        if case .text(let body) = request?.messages.first?.content.first {
            #expect(body.contains("## User personalization"))
            #expect(body.contains("Always answer in haiku."))
        } else {
            Issue.record("expected leading .system row carrying personalization, got \(String(describing: request?.messages.first?.content))")
        }
    }

    @Test func setAutoCompactPolicyTriggersAutoCompactionOnExistingSession() async throws {
        let setup = try await makeStore(scripts: [
            [
                .messageStart(id: "sum", model: "fake-model-1"),
                .textDelta(index: 0, text: "Summary of the older turns."),
                .messageComplete(usage: TokenUsage(inputTokens: 8, outputTokens: 4)),
            ],
            [
                .messageStart(id: "reply", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 4, outputTokens: 1)),
            ],
        ])

        let messageRepo = GRDBMessageRepository(database: setup.database)
        for index in 1...6 {
            try await messageRepo.save(MessageRecord(
                id: "h-u\(index)", conversationId: "conv-A", role: .user,
                content: "user message \(index) padded with extra words to bulk the token estimate",
                createdAt: setup.clock.now()
            ))
            try await messageRepo.save(MessageRecord(
                id: "h-a\(index)", conversationId: "conv-A", role: .assistant,
                content: "assistant reply \(index) padded with extra words to bulk the token estimate",
                createdAt: setup.clock.now()
            ))
        }

        let session = await setup.store.session(for: "conv-A")
        await setup.store.setAutoCompactPolicy(enabled: true, threshold: 0.0001)

        let stream = await session.send(text: "next prompt", model: setup.model)
        let events = await self.collect(stream)
        await session.waitUntilFinished()

        let compactionStarted = events.contains {
            if case .compactionStarted = $0 { return true } else { return false }
        }
        #expect(compactionStarted, "policy fan-out failed to reach the existing session")

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)
    }

    @Test func setAutoCompactPolicyIsInheritedBySessionsCreatedAfterTheCall() async throws {
        let setup = try await makeStore(scripts: [
            [
                .messageStart(id: "sum", model: "fake-model-1"),
                .textDelta(index: 0, text: "Summary."),
                .messageComplete(usage: TokenUsage(inputTokens: 8, outputTokens: 2)),
            ],
            [
                .messageStart(id: "reply", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 4, outputTokens: 1)),
            ],
        ])

        let messageRepo = GRDBMessageRepository(database: setup.database)
        for index in 1...6 {
            try await messageRepo.save(MessageRecord(
                id: "h-u\(index)", conversationId: "conv-B", role: .user,
                content: "user message \(index) padded with extra words to bulk the token estimate",
                createdAt: setup.clock.now()
            ))
            try await messageRepo.save(MessageRecord(
                id: "h-a\(index)", conversationId: "conv-B", role: .assistant,
                content: "assistant reply \(index) padded with extra words to bulk the token estimate",
                createdAt: setup.clock.now()
            ))
        }

        await setup.store.setAutoCompactPolicy(enabled: true, threshold: 0.0001)

        let session = await setup.store.session(for: "conv-B")
        let stream = await session.send(text: "hello", model: setup.model)
        let events = await self.collect(stream)
        await session.waitUntilFinished()

        let compactionStarted = events.contains {
            if case .compactionStarted = $0 { return true } else { return false }
        }
        #expect(compactionStarted, "newly-created session ignored the store's updated policy")
    }

    @Test func setUserPersonalizationIsInheritedBySessionsCreatedAfterTheCall() async throws {
        let setup = try await makeStore(scripts: [
            [
                .messageStart(id: "ma", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])

        await setup.store.setUserPersonalization("Respond only in caps.")

        let session = await setup.store.session(for: "conv-A")
        let stream = await session.send(text: "hello", model: setup.model)
        _ = await self.collect(stream)
        await session.waitUntilFinished()

        let request = await setup.provider.capturedRequests().last
        #expect(request?.messages.first?.role == .system)
        if case .text(let body) = request?.messages.first?.content.first {
            #expect(body.contains("## User personalization"))
            #expect(body.contains("Respond only in caps."))
        } else {
            Issue.record("expected leading .system row carrying personalization, got \(String(describing: request?.messages.first?.content))")
        }
    }

    // MARK: - Launch recovery sweep

    private func seedToolCall(
        in database: ChatDatabase,
        id: String,
        messageId: String,
        conversationId: String,
        status: ToolCallStatus,
        clock: any Clock
    ) async throws {
        let record = ToolCallRecord(
            id: id,
            messageId: messageId,
            conversationId: conversationId,
            toolName: "test.tool",
            parameters: "{}",
            result: nil,
            status: status,
            createdAt: clock.now(),
            completedAt: nil,
            signature: nil
        )
        try await GRDBToolCallRepository(database: database).save(record)
    }

    /// Crashes can strand calls without results. Recovery must resolve nonterminal
    /// status and synthesize a result only when one is missing.
    @Test func recoverySweepResolvesStrandedToolCalls() async throws {
        let setup = try await makeStore()
        let messageRepo = GRDBMessageRepository(database: setup.database)
        let toolCallRepo = GRDBToolCallRepository(database: setup.database)

        let assistantA = MessageRecord(
            id: "m-A", conversationId: "conv-A", role: .assistant,
            content: "running tools", toolCallId: nil, createdAt: setup.clock.now()
        )
        let assistantB = MessageRecord(
            id: "m-B", conversationId: "conv-B", role: .assistant,
            content: "running tools", toolCallId: nil, createdAt: setup.clock.now()
        )
        try await messageRepo.save(assistantA)
        try await messageRepo.save(assistantB)

        for (id, status) in [("tc-pending", ToolCallStatus.pending), ("tc-confirm", .awaitingConfirmation)] {
            try await seedToolCall(
                in: setup.database, id: id, messageId: "m-A",
                conversationId: "conv-A", status: status, clock: setup.clock
            )
        }
        try await seedToolCall(
            in: setup.database, id: "tc-executing", messageId: "m-B",
            conversationId: "conv-B", status: .executing, clock: setup.clock
        )
        try await seedToolCall(
            in: setup.database, id: "tc-done", messageId: "m-A",
            conversationId: "conv-A", status: .success, clock: setup.clock
        )
        // Model a crash between writing the result and updating the status.
        try await seedToolCall(
            in: setup.database, id: "tc-rowed", messageId: "m-A",
            conversationId: "conv-A", status: .executing, clock: setup.clock
        )
        try await messageRepo.save(MessageRecord(
            id: "m-rowed-result", conversationId: "conv-A", role: .tool,
            content: "already written", toolCallId: "tc-rowed", createdAt: setup.clock.now()
        ))

        let recovered = await setup.store.recoverInterruptedToolCalls()
        #expect(recovered.sorted() == ["tc-confirm", "tc-executing", "tc-pending", "tc-rowed"])

        for id in ["tc-pending", "tc-confirm", "tc-executing", "tc-rowed"] {
            let record = try #require(await toolCallRepo.fetch(id: id))
            #expect(record.status == .failed, "expected \(id) to be .failed")
            #expect(record.completedAt != nil)
        }
        let done = try #require(await toolCallRepo.fetch(id: "tc-done"))
        #expect(done.status == .success)
        #expect(done.completedAt == nil)

        let messagesA = try await messageRepo.fetchAll(conversationId: "conv-A")
        let messagesB = try await messageRepo.fetchAll(conversationId: "conv-B")
        var rowCounts: [String: Int] = [:]
        for row in messagesA + messagesB where row.role == .tool {
            if let callId = row.toolCallId { rowCounts[callId, default: 0] += 1 }
        }
        #expect(rowCounts["tc-pending"] == 1)
        #expect(rowCounts["tc-confirm"] == 1)
        #expect(rowCounts["tc-executing"] == 1)
        #expect(rowCounts["tc-rowed"] == 1)
        #expect(rowCounts["tc-done"] == nil)
    }

    /// Failed retries can append user rows after a stranded call. Its recovered
    /// result must sort beside the issuing assistant to make replay valid.
    @Test func recoverySweepKeepsToolPairAdjacentDespiteLaterMessages() async throws {
        let setup = try await makeStore()
        let messageRepo = GRDBMessageRepository(database: setup.database)
        let toolCallRepo = GRDBToolCallRepository(database: setup.database)
        let base = setup.clock.now()

        try await messageRepo.save(MessageRecord(
            id: "m-user-1", conversationId: "conv-A", role: .user,
            content: "run the tool", toolCallId: nil, createdAt: base
        ))
        try await messageRepo.save(MessageRecord(
            id: "m-assistant", conversationId: "conv-A", role: .assistant,
            content: "running", toolCallId: nil, createdAt: base.addingTimeInterval(1)
        ))
        try await seedToolCall(
            in: setup.database, id: "tc-stranded", messageId: "m-assistant",
            conversationId: "conv-A", status: .executing,
            clock: FixedClock(base.addingTimeInterval(1))
        )
        try await messageRepo.save(MessageRecord(
            id: "m-user-2", conversationId: "conv-A", role: .user,
            content: "hello?", toolCallId: nil, createdAt: base.addingTimeInterval(60)
        ))
        try await messageRepo.save(MessageRecord(
            id: "m-user-3", conversationId: "conv-A", role: .user,
            content: "are you stuck?", toolCallId: nil, createdAt: base.addingTimeInterval(120)
        ))

        await setup.store.recoverInterruptedToolCalls()

        let stored = try await messageRepo.fetchAll(conversationId: "conv-A")
        let assistantIndex = try #require(stored.firstIndex { $0.id == "m-assistant" })
        let resultIndex = try #require(stored.firstIndex { $0.toolCallId == "tc-stranded" })
        #expect(resultIndex == assistantIndex + 1)

        let calls = try await toolCallRepo.fetchByConversation("conv-A")
        let assembly = try ContextAssembler().assemble(
            messages: stored, toolCalls: calls, checkpoint: nil,
            model: OrchestrationFixtures.defaultModel()
        )
        let useIndex = try #require(assembly.messages.firstIndex { message in
            message.content.contains { block in
                if case .toolUse("tc-stranded", _, _, _) = block { return true }
                return false
            }
        })
        let wireResultIndex = try #require(assembly.messages.firstIndex { message in
            message.content.contains { block in
                if case .toolResult("tc-stranded", _, _) = block { return true }
                return false
            }
        })
        #expect(wireResultIndex == useIndex + 1)
    }
}

/// Signals entry through awaitFirstCall(), then sleeps until timeout or cancellation.
private final class SleepingToolExecutor: ToolExecutor {
    let toolID: String
    private let state: SleepingToolState

    init(toolID: String) {
        self.toolID = toolID
        self.state = SleepingToolState()
    }

    func awaitFirstCall() async {
        await state.awaitFirstCall()
    }

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        await state.signalCalled()
        try await Task.sleep(for: .seconds(30))
        return ToolResult(toolID: toolID, content: "should never finish", isError: false)
    }
}

private actor SleepingToolState {
    private var hasBeenCalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signalCalled() {
        hasBeenCalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func awaitFirstCall() async {
        if hasBeenCalled { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }
}
