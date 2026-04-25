import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ChatSession`'s single-turn behavior: persistence ordering,
/// streaming-text accumulation per ADR-BB-003 (write only on
/// `.messageComplete`), event sequence, and provider failure surfaces.
@Suite("ChatSession")
struct ChatSessionTests {

    private struct Setup {
        let database: ChatDatabase
        let messageRepo: GRDBMessageRepository
        let toolCallRepo: GRDBToolCallRepository
        let conversationRepo: GRDBConversationRepository
        let llmRegistry: LLMProviderRegistry
        let toolRegistry: ToolRegistry
        let clock: MonotonicClock
        let idGen: DeterministicIDGenerator
        let provider: FakeLLMProvider
        let conversation: ConversationRecord
        let model: LLMModel
        let session: ChatSession
    }

    private func makeSetup(
        scripts: [[LLMStreamEvent]] = [],
        registerProvider: Bool = true
    ) async throws -> Setup {
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
        if registerProvider { await llmRegistry.register(provider) }

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
            database: database,
            messageRepo: messageRepo,
            toolCallRepo: toolCallRepo,
            conversationRepo: conversationRepo,
            llmRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            clock: clock,
            idGen: idGen,
            provider: provider,
            conversation: conversation,
            model: model,
            session: session
        )
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func userMessageIsPersistedBeforeAnyAssistantWrite() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "Hi"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hello", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .userMessageSaved(let userRecord) = events.first else {
            Issue.record("expected first event to be .userMessageSaved, got \(String(describing: events.first))")
            return
        }
        #expect(userRecord.role == .user)
        #expect(userRecord.content == "Hello")
        #expect(userRecord.id == "id-1")

        let storedUser = try await setup.messageRepo.fetch(id: userRecord.id)
        #expect(storedUser != nil)
    }

    @Test func textDeltasAccumulateAndAssistantSavesOnceOnMessageComplete() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "Hello "),
                .textDelta(index: 0, text: "world"),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 2)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // Two textDelta events surface to the view.
        let textDeltas = events.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }
        #expect(textDeltas == ["Hello ", "world"])

        // Exactly one assistant message lands in the database, with
        // the accumulated text and the usage's output token count.
        let assistantSavedCount = events.filter {
            if case .assistantMessageSaved = $0 { return true }
            return false
        }.count
        #expect(assistantSavedCount == 1)

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant])
        #expect(stored.last?.content == "Hello world")
        #expect(stored.last?.tokenCount == 2)
    }

    @Test func intermediateTextDeltasNeverWriteToDatabase() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "a"),
                .textDelta(index: 0, text: "b"),
                .textDelta(index: 0, text: "c"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "ping", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        // 1 user + 1 assistant only — no per-delta intermediate rows.
        #expect(stored.count == 2)
        #expect(stored.last?.content == "abc")
    }

    @Test func providerErrorEventEndsTurnWithErrorAndNoAssistantRow() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .error(.unauthorized),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // Last event is the terminal .error.
        guard case .error(let llmError) = events.last else {
            Issue.record("expected trailing .error, got \(String(describing: events.last))")
            return
        }
        #expect(llmError == .unauthorized)

        // No .assistantMessageSaved fired.
        let assistantSavedCount = events.filter {
            if case .assistantMessageSaved = $0 { return true }
            return false
        }.count
        #expect(assistantSavedCount == 0)

        // DB has only the user row.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user])
    }

    @Test func missingActiveProviderEmitsRequestFailedError() async throws {
        let setup = try await makeSetup(registerProvider: false)
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .error(let llmError) = events.last else {
            Issue.record("expected .error, got \(String(describing: events.last))")
            return
        }
        if case .requestFailed = llmError {
            // expected
        } else {
            Issue.record("expected .requestFailed, got \(llmError)")
        }
    }

    @Test func priorMessagesArePassedToProviderInChronologicalOrder() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        // Pre-seed two prior messages.
        let now = setup.clock.now()
        try await setup.messageRepo.save(MessageRecord(
            id: "seed-1", conversationId: setup.conversation.id,
            role: .user, content: "previous user", createdAt: now
        ))
        try await setup.messageRepo.save(MessageRecord(
            id: "seed-2", conversationId: setup.conversation.id,
            role: .assistant, content: "previous reply", createdAt: setup.clock.now()
        ))

        let stream = await setup.session.send(text: "third", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 1)
        let messages = captured.first?.messages ?? []
        #expect(messages.count == 3)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[2].role == .user)

        // The new user turn carries the submitted text.
        if case .text(let body) = messages[2].content.first {
            #expect(body == "third")
        } else {
            Issue.record("expected user text content, got \(messages[2].content)")
        }
    }

    @Test func temperatureForwardsToProvider() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model, temperature: 0.42)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        #expect(captured.first?.temperature == 0.42)
    }

    @Test func thinkingDeltasSurfaceAsThinkingEvents() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .thinkingDelta(index: 0, text: "reasoning..."),
                .textDelta(index: 1, text: "answer"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        let thinking = events.compactMap { event -> String? in
            if case .thinkingDelta(let text) = event { return text }
            return nil
        }
        #expect(thinking == ["reasoning..."])
    }

    @Test func assistantMessageSavedEventCarriesPersistedRow() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "done"),
                .messageComplete(usage: TokenUsage(inputTokens: 3, outputTokens: 4)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .assistantMessageSaved(let record) = events.last else {
            Issue.record("expected trailing .assistantMessageSaved, got \(String(describing: events.last))")
            return
        }
        let stored = try await setup.messageRepo.fetch(id: record.id)
        #expect(stored?.id == record.id)
        #expect(stored?.role == record.role)
        #expect(stored?.content == record.content)
        #expect(stored?.tokenCount == 4)
    }
}
