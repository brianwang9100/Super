import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ChatSession`'s tool loop: pending → executing → success
/// transitions, tool result `MessageRecord` round-trip, multi-turn history
/// assembly, and enabled-tool filtering before the LLM (Large Language
/// Model) sees the catalog.
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
            // Turn 1: assistant emits some text + a tool call.
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "checking..."),
                .toolUse(index: 0, id: "tc-1", name: toolID, input: .object(["q": .string("ping")])),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            // Turn 2: after the tool returns, the assistant finishes plainly.
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

        // The tool was invoked once.
        let count = await executor.executionCount()
        #expect(count == 1)
        // ...with the parameters the LLM emitted.
        let inputs = await executor.capturedInputs()
        #expect(inputs.first?["q"] == .string("ping"))

        // Persisted ToolCallRecord landed at status .success with the
        // result body JSON-encoded.
        let storedCall = try await setup.toolCallRepo.fetch(id: "tc-1")
        #expect(storedCall?.status == .success)
        #expect(storedCall?.toolName == toolID)
        #expect(storedCall?.completedAt != nil)

        // Conversation now has user + assistant1 + tool result + assistant2.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant, .tool, .assistant])
        // The .tool row is linked back to the call.
        let toolRow = stored[2]
        #expect(toolRow.toolCallId == "tc-1")
        #expect(toolRow.content == "pong")
        // The final assistant carries the second-turn text.
        #expect(stored.last?.content == "result was 'pong'")

        // Event sequence carried both lifecycle markers for the tool call.
        let kinds = events.map { event -> String in
            switch event {
            case .userMessageSaved: return "user"
            case .textDelta: return "text"
            case .thinkingDelta: return "thinking"
            case .toolCallStarted: return "toolStarted"
            case .toolCallCompleted: return "toolCompleted"
            case .toolCallFailed: return "toolFailed"
            case .assistantMessageSaved: return "assistantSaved"
            case .compactionStarted: return "compactionStarted"
            case .compactionCompleted: return "compactionCompleted"
            case .error: return "error"
            }
        }
        // Order around the tool: assistant text, assistant saved, tool
        // started, tool completed, second-turn text, final assistant saved.
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
                .toolUse(index: 0, id: "tc-x", name: toolID, input: .object([:])),
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
        // user, assistant(toolUse only — empty text), tool(result)
        #expect(secondTurnMessages.count == 3)
        #expect(secondTurnMessages[1].role == .assistant)
        if case .toolUse(let id, let name, _) = secondTurnMessages[1].content.first {
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
                .toolUse(index: 0, id: "tc-bad", name: toolID, input: .object([:])),
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

        // ToolCallRecord ended at .failed with an error result body.
        let storedCall = try await setup.toolCallRepo.fetch(id: "tc-bad")
        #expect(storedCall?.status == .failed)
        #expect(storedCall?.completedAt != nil)

        // A .toolCallFailed event surfaced.
        let failed = events.contains { event in
            if case .toolCallFailed = event { return true }
            return false
        }
        #expect(failed)

        // The second turn's history carries the failure as an isError tool
        // result — that is how the LLM learns to apologize.
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
        // The result column should always hold a JSON-encoded `ToolResult`
        // — both on success and failure — so admin tools and analytics
        // can `decodedResult()` without distinguishing the two paths.
        let toolID = "test.broken.parse"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-parse", name: toolID, input: .object([:])),
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
        // Regression test for the prior `try?`-swallowed DB writes in the
        // failure branch. The error-content `MessageRecord` (role .tool)
        // must actually land so the next turn's history carries it.
        let toolID = "test.broken.row"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-row", name: toolID, input: .object([:])),
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
        // The provider can emit several `.toolUse` events in one turn
        // (parallel function calling). The orchestrator runs them one at
        // a time in emission order; each should be persisted, executed,
        // and yield its own ChatEvent triplet.
        let toolA = "test.a"
        let toolB = "test.b"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-a", name: toolA, input: .object([:])),
                .toolUse(index: 1, id: "tc-b", name: toolB, input: .object([:])),
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

        // Second turn's history carries both tool results, in order.
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
                // Two citation events; the second repeats `dupeURL`, which must
                // collapse to a single stored source (first-seen wins).
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
        // First-seen wins on dedupe: the later "A (dupe)" title is discarded.
        #expect(sources.first?.title == "A")
    }
}
