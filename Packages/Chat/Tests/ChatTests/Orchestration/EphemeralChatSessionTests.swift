import Core
import Foundation
import Testing

@testable import Chat

@Suite("Ephemeral ChatSession")
struct EphemeralChatSessionTests {
    private let complete = LLMStreamEvent.messageComplete(usage: .init(inputTokens: 3, outputTokens: 5))

    private func makeSession(
        provider: any LLMProvider,
        tools: ToolRegistry = ToolRegistry(),
        configuration: ChatSessionConfiguration = .init(tools: .disabled, requiresCompleteResponse: true)
    ) async throws -> ChatSession {
        try await ChatSession.makeEphemeral(
            provider: provider,
            toolRegistry: tools,
            briefing: "Write a focused study note.",
            configuration: configuration,
            clock: OrchestrationFixtures.defaultClock(),
            idGenerator: DeterministicIDGenerator()
        )
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("subsequent sends keep context while separate ephemeral sessions stay isolated")
    func multipleTurnsAndIsolation() async throws {
        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        for text in ["First answer", "Second answer", "Separate answer"] {
            await provider.enqueue([.textDelta(index: 0, text: text), complete])
        }
        let session = try await makeSession(provider: provider)
        let driver = LiveChatSessionDriver(session: session)
        _ = await collect(driver.send(text: "First question", model: model, references: []))
        _ = await collect(session.send(text: "Follow up", model: model))
        let separate = try await makeSession(provider: provider)
        _ = await collect(separate.send(text: "Separate question", model: model))

        let requests = await provider.capturedRequests()
        #expect(requests.count == 3)
        #expect(requests[1].messages.filter { $0.role != .system } == [
            LLMMessage(role: .user, text: "First question"),
            LLMMessage(role: .assistant, text: "First answer"),
            LLMMessage(role: .user, text: "Follow up"),
        ])
        #expect(requests[2].messages.filter { $0.role != .system } == [
            LLMMessage(role: .user, text: "Separate question"),
        ])
        #expect(requests.allSatisfy { $0.temperature == 1.0 && $0.options.requiresCompleteResponse })
    }

    @Test("the selected provider stays pinned if the app's active model changes before sending")
    func pinnedProvider() async throws {
        let model = OrchestrationFixtures.defaultModel()
        let original = FakeLLMProvider(id: "original", model: model)
        await original.enqueue([.textDelta(index: 0, text: "Original answer"), complete])
        let replacement = FakeLLMProvider(id: "replacement", model: LLMModel(id: "different-model", displayName: "Different"))
        let appRegistry = LLMProviderRegistry()
        await appRegistry.register(original)
        await appRegistry.register(replacement)
        let selected = try await appRegistry.requireActive()
        let session = try await makeSession(provider: selected)
        try await appRegistry.setActive(id: replacement.id)
        _ = await collect(session.send(text: "Question", model: model))
        #expect(await original.capturedRequests().first?.modelID == model.id)
        #expect(await replacement.capturedRequests().isEmpty)
    }

    @Test("disabled tools suppress registered tools, native and mock search, and search instructions", arguments: [nil, "native", "debug"] as [String?])
    func disabledTools(searchBackend: String?) async throws {
        let model = LLMModel(id: "search-model", displayName: "Search", searchBackend: searchBackend)
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([.textDelta(index: 0, text: "A note"), complete])
        let tools = ToolRegistry()
        await tools.register(ToolRegistration(
            tool: LLMTool(id: "test.write", name: "test.write", description: "Write", category: .mutation, parameters: [], appletId: "test"),
            execution: .local(FakeToolExecutor(toolID: "test.write")), isEnabled: true
        ))
        let session = try await makeSession(provider: provider, tools: tools)
        _ = await collect(session.send(text: "Question", model: model))
        let request = try #require(await provider.capturedRequests().first)
        #expect(request.tools.isEmpty)
        #expect(!request.messages.contains { message in
            message.content.contains { if case .text(let text) = $0 { return text.contains("## Web search") }; return false }
        })
    }

    @Test("unsolicited tool calls fail before any tool write or saved assistant event")
    func unsolicitedTool() async throws {
        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([
            .textDelta(index: 0, text: "A note"),
            .toolUse(index: 1, id: "call", name: "test.write", input: .object([:]), signature: nil), complete,
        ])
        let tools = ToolRegistry()
        let executor = FakeToolExecutor(toolID: "test.write")
        await tools.register(ToolRegistration(
            tool: LLMTool(id: "test.write", name: "test.write", description: "Write", category: .mutation, parameters: [], appletId: "test"),
            execution: .local(executor), isEnabled: true
        ))
        let session = try await makeSession(provider: provider, tools: tools)
        let events = await collect(session.send(text: "Question", model: model))
        #expect(events.contains { if case .error = $0 { return true }; return false })
        #expect(!events.contains { if case .assistantMessageSaved = $0 { return true }; return false })
        #expect(await executor.executionCount() == 0)
    }

    @Test("strict completion rejects missing terminal, late content, late errors, and textless responses", arguments: [
        [LLMStreamEvent.textDelta(index: 0, text: "Partial")],
        [.textDelta(index: 0, text: " \n"), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0))],
        [.thinkingDelta(index: 0, text: "Thinking"), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0))],
        [.textDelta(index: 0, text: "Text"), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0)), .textDelta(index: 0, text: "Late")],
        [.textDelta(index: 0, text: "Text"), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0)), .error(.requestFailed("Late error"))],
    ])
    func strictCompletion(script: [LLMStreamEvent]) async throws {
        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue(script)
        let session = try await makeSession(provider: provider)
        let events = await collect(session.send(text: "Question", model: model))
        #expect(events.contains { if case .error = $0 { return true }; return false })
        #expect(!events.contains { if case .assistantMessageSaved = $0 { return true }; return false })
    }

    @Test("a cancelled caller cannot start a billable turn")
    func cancelledStartup() async throws {
        let provider = FakeLLMProvider(model: OrchestrationFixtures.defaultModel())
        let session = try await makeSession(provider: provider)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = await session.send(text: "Question", model: OrchestrationFixtures.defaultModel())
        }.value
        await session.waitUntilFinished()
        #expect(await provider.capturedRequests().isEmpty)
        #expect(await !session.isStreaming)
    }

    @Test("only strict sessions reject completed output before the repository cancellation boundary", arguments: [false, true])
    func cancelledAtEOF(requiresCompleteResponse: Bool) async throws {
        let provider = CancelAtEOFProvider()
        let database = try ChatDatabase.makeInMemory()
        let clock = OrchestrationFixtures.defaultClock()
        let ids = DeterministicIDGenerator()
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)
        let messages = SaveAttemptMessageRepository(base: GRDBMessageRepository(database: database))
        let providers = LLMProviderRegistry()
        await providers.register(provider)
        let session = ChatSession(
            conversationId: conversation.id,
            messageRepository: messages,
            toolCallRepository: GRDBToolCallRepository(database: database),
            checkpointRepository: GRDBCompactionCheckpointRepository(database: database),
            llmProviderRegistry: providers,
            toolRegistry: ToolRegistry(),
            compactor: OrchestrationFixtures.makeCompactor(
                database: database, llmRegistry: providers, clock: clock, idGenerator: ids
            ),
            clock: clock,
            idGenerator: ids,
            configuration: .init(tools: .disabled, requiresCompleteResponse: requiresCompleteResponse)
        )
        let events = await collect(session.send(text: "Question", model: provider.supportedModels[0]))
        await session.waitUntilFinished()
        #expect(await messages.assistantSaveAttempts == (requiresCompleteResponse ? [] : ["Complete text"]))
        // Ordinary Chat still delegates to GRDB, which cancels its write independently.
        #expect(events.contains { if case .error(.cancelled) = $0 { return true }; return false })
        #expect(!events.contains { if case .assistantMessageSaved = $0 { return true }; return false })
    }

    @Test("a replacement subscriber receives the in-flight snapshot and remaining response")
    func resubscribeAndCancel() async throws {
        let model = OrchestrationFixtures.defaultModel()
        let provider = PausableLLMProvider(model: model)
        let session = try await makeSession(provider: provider)
        let stream = await session.send(text: "Question", model: model)
        await provider.yield(.textDelta(index: 0, text: "Partial"))
        for await event in stream {
            if case .textDelta = event { break }
        }
        let subscription = await session.subscribe()
        #expect(subscription.snapshot?.accumulatedText == "Partial")
        await session.cancel()
        let events = await collect(subscription.stream)
        await session.waitUntilFinished()
        #expect(events.contains { if case .error(.cancelled) = $0 { return true }; return false })
        #expect(!events.contains { if case .assistantMessageSaved = $0 { return true }; return false })
        #expect(await !session.isStreaming)
    }
}

private actor SaveAttemptMessageRepository: MessageRepository {
    let base: GRDBMessageRepository
    private(set) var assistantSaveAttempts: [String] = []

    init(base: GRDBMessageRepository) { self.base = base }

    func save(_ record: MessageRecord) async throws {
        if record.role == .assistant { assistantSaveAttempts.append(record.content) }
        try await base.save(record)
    }

    func fetchAll(conversationId: String) async throws -> [MessageRecord] {
        try await base.fetchAll(conversationId: conversationId)
    }

    func fetch(id: String) async throws -> MessageRecord? { try await base.fetch(id: id) }

    func hasUserMessage(conversationId: String) async throws -> Bool {
        try await base.hasUserMessage(conversationId: conversationId)
    }

    func delete(ids: [String]) async throws { try await base.delete(ids: ids) }

    func deleteAll(conversationId: String) async throws { try await base.deleteAll(conversationId: conversationId) }
}

private struct CancelAtEOFProvider: LLMProvider {
    let id = "cancel-at-eof"
    let displayName = "Cancel at EOF"
    let supportedModels = [OrchestrationFixtures.defaultModel()]

    func stream(messages: [LLMMessage], model: LLMModel, tools: [LLMTool], temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let events = Events()
        return AsyncThrowingStream(unfolding: { await events.next() })
    }

    private actor Events {
        private var index = 0

        func next() -> LLMStreamEvent? {
            defer { index += 1 }
            switch index {
            case 0: return .textDelta(index: 0, text: "Complete text")
            case 1: return .messageComplete(usage: .init(inputTokens: 0, outputTokens: 1))
            default:
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            }
        }
    }
}
