import Core
import Foundation
import Testing

@testable import Chat

@Suite("ChatSession tool loop")
struct ChatSessionToolLoopTests {

    private struct Setup {
        let database: ChatDatabase
        let messageRepo: GRDBMessageRepository
        let toolCallRepo: GRDBToolCallRepository
        let conversationRepo: GRDBConversationRepository
        let llmRegistry: LLMProviderRegistry
        let toolRegistry: ToolRegistry
        let clock: FixedClock
        let provider: FakeLLMProvider
        let conversation: ConversationRecord
        let model: LLMModel
        let session: ChatSession
    }

    private func makeSetup(scripts: [[LLMStreamEvent]] = []) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let conversationRepo = GRDBConversationRepository(database: database)
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)

        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

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
            autoCompactEnabled: false
        )
        return Setup(
            database: database, messageRepo: messageRepo, toolCallRepo: toolCallRepo,
            conversationRepo: conversationRepo, llmRegistry: llmRegistry,
            toolRegistry: toolRegistry, clock: clock, provider: provider,
            conversation: conversation, model: model, session: session
        )
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func makeTool(id: String) -> LLMTool {
        LLMTool(
            id: id, name: id, description: "test tool",
            category: .query, parameters: [], appletId: "test"
        )
    }

    @Test func loopExecutesToolThenContinuesUntilLLMFinishesWithoutToolCalls() async throws {
        let toolID = "test.echo"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "checking..."),
                .toolUse(index: 0, id: "tc-1", name: toolID, input: .object(["q": .string("ping")]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "result was 'pong'"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "pong", isError: false))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "ping the tool", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        let count = await executor.executionCount()
        #expect(count == 1)
        let inputs = await executor.capturedInputs()
        #expect(inputs.first?["q"] == .string("ping"))

        let storedCall = try await setup.toolCallRepo.fetch(id: "tc-1")
        #expect(storedCall?.status == .success)
        #expect(storedCall?.toolName == toolID)
        #expect(storedCall?.completedAt != nil)

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant, .tool, .assistant])
        let toolRow = stored[2]
        #expect(toolRow.toolCallId == "tc-1")
        #expect(toolRow.content == "pong")
        #expect(stored.last?.content == "result was 'pong'")

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
        #expect(kinds.contains("toolStarted"))
        #expect(kinds.contains("toolCompleted"))
        #expect(!kinds.contains("toolFailed"))
        #expect(!kinds.contains("error"))
    }

    @Test func secondTurnHistoryIncludesToolUseAndToolResultBlocks() async throws {
        let toolID = "test.lookup"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-x", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "{\"data\":42}", isError: false))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "look it up", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)

        let secondTurnMessages = captured[1].messages
        #expect(secondTurnMessages.count == 3)
        #expect(secondTurnMessages[1].role == .assistant)
        if case .toolUse(let id, let name, _, _) = secondTurnMessages[1].content.first {
            #expect(id == "tc-x")
            #expect(name == toolID)
        } else {
            Issue.record("expected first assistant block to be .toolUse, got \(secondTurnMessages[1].content)")
        }
        #expect(secondTurnMessages[2].role == .tool)
        if case .toolResult(let toolUseID, let content, let isError) = secondTurnMessages[2].content.first {
            #expect(toolUseID == "tc-x")
            #expect(content == "{\"data\":42}")
            #expect(isError == false)
        } else {
            Issue.record("expected tool message to carry .toolResult, got \(secondTurnMessages[2].content)")
        }
    }

    @Test func toolExecutionFailureMarksRecordFailedAndFeedsErrorBackToLLM() async throws {
        let toolID = "test.broken"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-bad", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "sorry, that failed"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setError(.scripted("DB locked"))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "do it", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        let storedCall = try await setup.toolCallRepo.fetch(id: "tc-bad")
        #expect(storedCall?.status == .failed)
        #expect(storedCall?.completedAt != nil)

        let failed = events.contains { event in
            if case .toolCallFailed = event { return true }
            return false
        }
        #expect(failed)

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)
        let toolRow = captured[1].messages.last
        #expect(toolRow?.role == .tool)
        if case .toolResult(_, _, let isError) = toolRow?.content.first {
            #expect(isError == true)
        } else {
            Issue.record("expected isError tool result, got \(String(describing: toolRow?.content))")
        }
    }

    @Test func disabledToolsAreFilteredBeforeReachingTheProvider() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let enabledExecutor = FakeToolExecutor(toolID: "test.on")
        let disabledExecutor = FakeToolExecutor(toolID: "test.off")
        await setup.toolRegistry.register(ToolRegistration(
            tool: makeTool(id: "test.on"), execution: .local(enabledExecutor), isEnabled: true
        ))
        await setup.toolRegistry.register(ToolRegistration(
            tool: makeTool(id: "test.off"), execution: .local(disabledExecutor), isEnabled: false
        ))

        let stream = await setup.session.send(text: "hi", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        let toolIDs = captured.first?.tools.map(\.id).sorted() ?? []
        #expect(toolIDs == ["test.on"])
    }

    @Test func failedToolCallResultColumnDecodesAsToolResult() async throws {
        let toolID = "test.broken.parse"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-parse", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setError(.scripted("kaboom"))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "do it", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let storedCall = try await setup.toolCallRepo.fetch(id: "tc-parse")
        guard let resultJSON = storedCall?.result else {
            Issue.record("expected stored result")
            return
        }
        let data = Data(resultJSON.utf8)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded.isError == true)
        #expect(decoded.content.contains("kaboom"))
    }

    @Test func toolFailurePersistsTheToolResultMessageRow() async throws {
        let toolID = "test.broken.row"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-row", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setError(.scripted("nope"))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "do it", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let toolRow = stored.first(where: { $0.role == .tool })
        #expect(toolRow != nil)
        #expect(toolRow?.toolCallId == "tc-row")
        #expect(toolRow?.content.contains("nope") == true)
    }

    @Test func multipleToolCallsInOneTurnAreAllExecutedSequentially() async throws {
        // Parallel provider calls execute serially in emission order.
        let toolA = "test.a"
        let toolB = "test.b"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-a", name: toolA, input: .object([:]), signature: nil),
                .toolUse(index: 1, id: "tc-b", name: toolB, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "all done"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let executorA = FakeToolExecutor(toolID: toolA)
        let executorB = FakeToolExecutor(toolID: toolB)
        await executorA.setResult(ToolResult(toolID: toolA, content: "A"))
        await executorB.setResult(ToolResult(toolID: toolB, content: "B"))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolA), execution: .local(executorA)))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolB), execution: .local(executorB)))

        let stream = await setup.session.send(text: "go", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let countA = await executorA.executionCount()
        let countB = await executorB.executionCount()
        #expect(countA == 1)
        #expect(countB == 1)

        let storedCalls = try await setup.toolCallRepo.fetchByConversation(setup.conversation.id)
        #expect(storedCalls.map(\.id) == ["tc-a", "tc-b"])
        #expect(storedCalls.allSatisfy { $0.status == .success })

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)
        let toolRows = captured[1].messages.filter { $0.role == .tool }
        #expect(toolRows.count == 2)
    }

    @Test func citationsArePersistedOntoAssistantMessageDedupedByURL() async throws {
        let dupeURL = URL(string: "https://example.com/a")!
        let otherURL = URL(string: "https://example.com/b")!
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .searchStarted(query: "history of westphalia"),
                .textDelta(index: 0, text: "The treaty was signed in 1648."),
                .citations([
                    SourceCitation(id: "s1", title: "A", url: dupeURL),
                    SourceCitation(id: "s2", title: "B", url: otherURL),
                ]),
                .citations([
                    SourceCitation(id: "s3", title: "A (dupe)", url: dupeURL),
                ]),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])

        let stream = await setup.session.send(text: "tell me about the treaty", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let assistant = try #require(stored.last)
        #expect(assistant.role == .assistant)
        let sources = assistant.attachments?.sources ?? []
        #expect(sources.count == 2)
        #expect(sources.map(\.url) == [dupeURL, otherURL])
        #expect(sources.first?.title == "A")
    }

    @Test func citationsOnlyTurnWithoutTextStillPersistsAssistantMessageWithSources() async throws {
        // Citations-only output must survive the empty-turn guard or its sources are lost.
        let url = URL(string: "https://example.com/grounded")!
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .searchStarted(query: "q"),
                .citations([SourceCitation(id: "s1", title: "Grounded", url: url)]),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 0)),
            ],
        ])

        let stream = await setup.session.send(text: "ground this", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant])
        let assistant = try #require(stored.last)
        #expect(assistant.content.isEmpty)
        #expect(assistant.attachments?.sources.map(\.url) == [url])
    }

    @Test func citationDedupeIsCaseInsensitiveOnSchemeAndHost() async throws {
        // Deduplicate host/scheme casing without folding case-sensitive paths.
        let first = URL(string: "https://Example.com/Article")!
        let dupe = URL(string: "HTTPS://example.com/Article")!
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "grounded"),
                .citations([
                    SourceCitation(id: "s1", title: "First", url: first),
                    SourceCitation(id: "s2", title: "Dupe (case)", url: dupe),
                ]),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])

        let stream = await setup.session.send(text: "q", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let sources = try #require(stored.last?.attachments?.sources)
        #expect(sources.count == 1)
        #expect(sources.first?.title == "First")
    }

    /// Cancelled batches still need results for every call, including unexecuted ones,
    /// or strict providers reject the next replay.
    @Test func cancelDuringToolExecutionWritesCancelledResultsForWholeBatch() async throws {
        let slowToolID = "test.slow"
        let fastToolID = "test.fast"
        let slowExecutor = ResumableToolExecutor(toolID: slowToolID)
        let fastExecutor = FakeToolExecutor(toolID: fastToolID)
        await fastExecutor.setResult(ToolResult(toolID: fastToolID, content: "never runs", isError: false))

        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "running tools"),
                .toolUse(index: 0, id: "tc-slow", name: slowToolID, input: .object([:]), signature: nil),
                .toolUse(index: 1, id: "tc-fast", name: fastToolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        await setup.toolRegistry.register(
            ToolRegistration(tool: makeTool(id: slowToolID), execution: .local(slowExecutor))
        )
        await setup.toolRegistry.register(
            ToolRegistration(tool: makeTool(id: fastToolID), execution: .local(fastExecutor))
        )

        let stream = await setup.session.send(text: "run both", model: setup.model)
        async let events: [ChatEvent] = self.collect(stream)

        await slowExecutor.awaitFirstCall()
        await setup.session.cancel()
        // This executor ignores cancellation; release it to verify the late result is discarded.
        await slowExecutor.resume(with: ToolResult(toolID: slowToolID, content: "late", isError: false))
        _ = await events
        await setup.session.waitUntilFinished()

        let slowCall = try #require(await setup.toolCallRepo.fetch(id: "tc-slow"))
        let fastCall = try #require(await setup.toolCallRepo.fetch(id: "tc-fast"))
        #expect(slowCall.status == .cancelled)
        #expect(fastCall.status == .cancelled)
        #expect(slowCall.completedAt != nil)
        #expect(fastCall.completedAt != nil)

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let toolRows = stored.filter { $0.role == .tool }
        #expect(toolRows.map(\.toolCallId).sorted { ($0 ?? "") < ($1 ?? "") } == ["tc-fast", "tc-slow"])

        let fastCount = await fastExecutor.executionCount()
        #expect(fastCount == 0)

        await setup.provider.enqueue([
            .messageStart(id: "m2", model: "fake-model-1"),
            .textDelta(index: 0, text: "fresh turn"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ])
        let secondStream = await setup.session.send(text: "continue", model: setup.model)
        _ = await collect(secondStream)
        await setup.session.waitUntilFinished()

        let requests = await setup.provider.capturedRequests()
        let lastRequest = try #require(requests.last)
        var toolUseIDs: [String] = []
        var toolResultIDs: [String] = []
        for message in lastRequest.messages {
            for block in message.content {
                if case .toolUse(let id, _, _, _) = block { toolUseIDs.append(id) }
                if case .toolResult(let id, _, _) = block { toolResultIDs.append(id) }
            }
        }
        #expect(toolUseIDs.sorted() == ["tc-fast", "tc-slow"])
        #expect(toolResultIDs.sorted() == ["tc-fast", "tc-slow"])
    }

    /// Mid-loop compaction must snap backward around a tool batch, preserving its
    /// real results rather than synthesizing interrupted-call repairs.
    @Test func midLoopAutoCompactionKeepsFollowUpPairComplete() async throws {
        let toolID = "test.batch"
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

        // Use full-tier total usage and a near-zero threshold to compact every iteration.
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

        // Scripts alternate compaction summaries and assistant turns in consumption order.
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

        let live = try #require(await checkpointRepo.liveCheckpoint(for: conversation.id))
        #expect(live.summary.contains("Summary two"))
        #expect(live.uptoMessageId == "seed-a3")

        let request = try #require(await provider.capturedRequests().last)
        let firstNonSystem = try #require(request.messages.first { $0.role != .system })
        #expect(firstNonSystem.role == .user)
        let firstTexts = firstNonSystem.content.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }
        #expect(firstTexts.contains { $0.contains("look up four things") })
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

    /// Reusing an id-less call key across turns makes upsert reparent the earlier
    /// call, leaving its result orphaned. Mint distinct persistence IDs.
    @Test func idlessToolCallsAcrossTurnsPersistAsDistinctRowsAndKeepEarlierToolUse() async throws {
        let toolID = "get_weather"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: toolID, name: toolID, input: .object(["c": .string("Paris")]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .toolUse(index: 0, id: toolID, name: toolID, input: .object(["c": .string("London")]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m3", model: "fake-model-1"),
                .textDelta(index: 0, text: "done"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "ok", isError: false))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        _ = await collect(await setup.session.send(text: "weather twice", model: setup.model))
        await setup.session.waitUntilFinished()

        let calls = try await setup.toolCallRepo.fetchByConversation(setup.conversation.id)
        #expect(calls.count == 2)
        #expect(Set(calls.map(\.id)).count == 2)
        #expect(calls.allSatisfy { $0.toolName == toolID })
        #expect(calls.allSatisfy { ToolCallRecord.isLocallyMintedID($0.id) })
        #expect(calls[0].messageId != calls[1].messageId)

        let lastRequest = try #require(await setup.provider.capturedRequests().last)
        var toolUseIDs: [String] = []
        for message in lastRequest.messages {
            for block in message.content {
                if case .toolUse(let id, _, _, _) = block { toolUseIDs.append(id) }
            }
        }
        #expect(toolUseIDs.count == 2)
        #expect(Set(toolUseIDs).count == 2)
    }

    /// Empty IDs need the same collision protection as the function-name fallback.
    @Test func emptyIDlessToolCallGetsALocallyMintedPK() async throws {
        let toolID = "lookup"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "done"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "ok", isError: false))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        _ = await collect(await setup.session.send(text: "look it up", model: setup.model))
        await setup.session.waitUntilFinished()

        let calls = try await setup.toolCallRepo.fetchByConversation(setup.conversation.id)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(!call.id.isEmpty)
        #expect(ToolCallRecord.isLocallyMintedID(call.id))
        #expect(call.toolName == toolID)
        let rows = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let toolRow = try #require(rows.first { $0.role == .tool })
        #expect(toolRow.toolCallId == call.id)
    }
}
