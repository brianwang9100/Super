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
        let clock: MonotonicClock
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
        let clock = MonotonicClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)

        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        for script in scripts { await provider.enqueue(script) }
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let toolRegistry = ToolRegistry()

        let session = ChatSession(
            conversationId: conversation.id,
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            clock: clock,
            idGenerator: idGen
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
}
