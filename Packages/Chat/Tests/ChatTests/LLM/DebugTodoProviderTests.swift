#if DEBUG
import Core
import Foundation
import Testing

@testable import Chat

/// Tests for the DEBUG-only `DebugTodoLLMProvider`: the canned `todo.create`
/// tool call it emits (titles parsed from the user turn, with a rich canned
/// fallback), the loop-termination guard that stops it creating forever, and
/// an end-to-end run through `ChatSession`'s tool loop against a fake
/// `todo.create` executor (the real Todo tool is covered by the Todo package's
/// own suite — Chat can't import Todo).
@Suite("Debug Todo provider")
struct DebugTodoProviderTests {

    /// Decodable mirror of one element in the tool's `tasks` JSON payload.
    private struct DecodedTask: Decodable {
        let title: String
        let priority: String?
        let dueAt: String?
        let notes: String?
    }

    // MARK: - Provider stream: tool call

    @Test func emitsTodoCreateToolCallWithTitlesParsedFromUserTurn() async throws {
        let provider = DebugTodoLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(
            provider, messages: [LLMMessage(role: .user, text: "add milk, eggs and bread")], model: model
        )

        let call = try #require(Self.firstToolUse(in: events))
        #expect(call.name == "todo.create")
        let tasks = try Self.decodeTasks(call.input)
        #expect(tasks.map(\.title) == ["milk", "eggs", "bread"])
    }

    @Test func fallsBackToRichCannedPayloadWhenNoTitlesParse() async throws {
        let provider = DebugTodoLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(
            provider, messages: [LLMMessage(role: .user, text: "   ")], model: model
        )

        let call = try #require(Self.firstToolUse(in: events))
        #expect(call.name == "todo.create")
        let tasks = try Self.decodeTasks(call.input)
        // Multiple tasks, exercising the optional fields the unit tests cover.
        #expect(tasks.count >= 2)
        #expect(tasks.contains { $0.priority != nil })
        #expect(tasks.contains { $0.dueAt != nil })
    }

    // MARK: - Provider stream: loop termination

    @Test func stopsAfterToolResultTurn() async throws {
        let provider = DebugTodoLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(provider, messages: Self.afterToolRanMessages(), model: model)

        #expect(Self.firstToolUse(in: events) == nil)
        let hasText = events.contains { if case .textDelta = $0 { return true } else { return false } }
        #expect(hasText)
    }

    @Test func stillCallsToolWhenEarlierToolResultPrecedesNewUserTurn() async throws {
        let provider = DebugTodoLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let messages = Self.afterToolRanMessages() + [LLMMessage(role: .user, text: "add walk the dog")]
        let events = try await Self.collect(provider, messages: messages, model: model)

        let call = try #require(Self.firstToolUse(in: events))
        #expect(call.name == "todo.create")
        let tasks = try Self.decodeTasks(call.input)
        #expect(tasks.map(\.title) == ["walk the dog"])
    }

    // MARK: - End-to-end through ChatSession's tool loop

    @Test func drivesOneToolCallThroughSessionThenStops() async throws {
        let provider = DebugTodoLLMProvider(id: "debug-todo-1")
        let setup = try await Self.makeSession(provider: provider)
        let executor = FakeToolExecutor(toolID: "todo.create")
        await executor.setResult(ToolResult(toolID: "todo.create", content: "ok"))
        await setup.toolRegistry.register(ToolRegistration(
            tool: Self.tool(id: "todo.create"), execution: .local(executor)
        ))

        let stream = await setup.session.send(text: "add milk and eggs", model: setup.model)
        _ = await Self.drain(stream)
        await setup.session.waitUntilFinished()

        #expect(await executor.executionCount() == 1)
        let input = try #require(await executor.capturedInputs().first)
        guard case .string(let json)? = input["tasks"] else {
            Issue.record("expected a `tasks` string param, got \(String(describing: input["tasks"]))")
            return
        }
        let tasks = try JSONDecoder().decode([DecodedTask].self, from: Data(json.utf8))
        #expect(tasks.map(\.title) == ["milk", "eggs"])
        // Loop terminated: user → assistant(toolUse) → tool → assistant(text).
        let roles = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id).map(\.role)
        #expect(roles == [.user, .assistant, .tool, .assistant])
    }

    // MARK: - Helpers

    private static func decodeTasks(_ input: JSONValue) throws -> [DecodedTask] {
        guard case .object(let dict) = input, case .string(let json)? = dict["tasks"] else {
            throw DecodeFailure.notATasksString
        }
        return try JSONDecoder().decode([DecodedTask].self, from: Data(json.utf8))
    }

    private enum DecodeFailure: Error { case notATasksString }

    /// A turn-loop history where the tool has already run — the provider must
    /// emit plain text (no further tool call) so the loop ends.
    private static func afterToolRanMessages() -> [LLMMessage] {
        [
            LLMMessage(role: .user, text: "add milk and eggs"),
            LLMMessage(role: .assistant, content: [.toolUse(id: "tc-1", name: "todo.create", input: .object([:]))]),
            LLMMessage(role: .tool, content: [.toolResult(toolUseID: "tc-1", content: "ok", isError: false)]),
        ]
    }

    private static func collect(
        _ provider: some LLMProvider, messages: [LLMMessage], model: LLMModel
    ) async throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for try await event in provider.stream(messages: messages, model: model, tools: [], temperature: 0) {
            events.append(event)
        }
        return events
    }

    private static func firstToolUse(
        in events: [LLMStreamEvent]
    ) -> (id: String, name: String, input: JSONValue)? {
        for event in events {
            if case .toolUse(_, let id, let name, let input) = event { return (id, name, input) }
        }
        return nil
    }

    private static func tool(id: String) -> LLMTool {
        LLMTool(id: id, name: id, description: "test", category: .mutation, parameters: [], appletId: "todo")
    }

    private static func drain(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private struct SessionSetup {
        let session: ChatSession
        let messageRepo: GRDBMessageRepository
        let toolRegistry: ToolRegistry
        let conversation: ConversationRecord
        let model: LLMModel
    }

    private static func makeSession(provider: some LLMProvider) async throws -> SessionSetup {
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let model = try #require(provider.supportedModels.first)
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
            autoCompactEnabled: false
        )
        return SessionSetup(
            session: session, messageRepo: messageRepo, toolRegistry: toolRegistry,
            conversation: conversation, model: model
        )
    }
}
#endif
