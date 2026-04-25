import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ChatSessionStore`'s session lifecycle: get-or-create
/// semantics, parallel session execution, and that cancelling one
/// conversation's session leaves siblings untouched.
@Suite("ChatSessionStore")
struct ChatSessionStoreTests {

    private struct StoreSetup {
        let database: ChatDatabase
        let store: ChatSessionStore
        let provider: FakeLLMProvider
        let model: LLMModel
        let toolRegistry: ToolRegistry
        let clock: MonotonicClock
    }

    private func makeStore(scripts: [[LLMStreamEvent]] = []) async throws -> StoreSetup {
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let conversationRepo = GRDBConversationRepository(database: database)
        let clock = MonotonicClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        for script in scripts { await provider.enqueue(script) }
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let toolRegistry = ToolRegistry()
        let store = ChatSessionStore(
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            clock: clock,
            idGenerator: idGen
        )

        // Two conversations live in the DB so the FK references resolve.
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

        // Both turns produced an .assistantMessageSaved as their last event.
        guard case .assistantMessageSaved = a.last,
              case .assistantMessageSaved = b.last else {
            Issue.record("expected both sessions to finish with assistantMessageSaved; got A=\(String(describing: a.last)), B=\(String(describing: b.last))")
            return
        }
    }

    @Test func cancellingOneSessionDoesNotAffectSiblings() async throws {
        // Session A's tool sleeps long enough to be cancellable.
        // Session B has no tool calls, just text.
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
            // Session A: ask for the sleeping tool, then a closing message
            // (we will never reach the closing turn because A is cancelled).
            [
                .messageStart(id: "ma", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-a", name: toolID, input: .object([:])),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 0)),
            ],
            // Session B: simple text reply.
            [
                .messageStart(id: "mb", model: "fake-model-1"),
                .textDelta(index: 0, text: "B done"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])

        await setup.toolRegistry.register(ToolRegistration(tool: toolDef, execution: .local(sleepingExecutor)))

        let sessionA = await setup.store.session(for: "conv-A")
        let sessionB = await setup.store.session(for: "conv-B")

        async let eventsA: [ChatEvent] = {
            let stream = await sessionA.send(text: "kick A", model: setup.model)
            return await self.collect(stream)
        }()
        async let eventsB: [ChatEvent] = {
            let stream = await sessionB.send(text: "kick B", model: setup.model)
            return await self.collect(stream)
        }()

        // Wait for the sleeping tool to actually start before cancelling, so
        // the cancellation lands inside `Task.sleep` rather than racing with
        // the user-message write.
        await sleepingExecutor.awaitFirstCall()
        await setup.store.cancel(for: "conv-A")

        let (a, b) = await (eventsA, eventsB)
        await sessionA.waitUntilFinished()
        await sessionB.waitUntilFinished()

        // A ends with .error(.cancelled).
        guard case .error(let llmError) = a.last else {
            Issue.record("expected A to terminate with .error, got \(String(describing: a.last))")
            return
        }
        #expect(llmError == .cancelled)

        // B finished its turn unaffected.
        guard case .assistantMessageSaved = b.last else {
            Issue.record("expected B to finish with .assistantMessageSaved, got \(String(describing: b.last))")
            return
        }
    }

    @Test func shutdownCancelsAllAndDropsSessions() async throws {
        let setup = try await makeStore(scripts: [
            [
                .messageStart(id: "ma", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let sessionA = await setup.store.session(for: "conv-A")
        let stream = await sessionA.send(text: "ping", model: setup.model)
        _ = await self.collect(stream)
        await sessionA.waitUntilFinished()

        await setup.store.shutdown()
        // After shutdown, requesting the same conversation yields a fresh
        // session instance because the store dropped its registry.
        let sessionAReborn = await setup.store.session(for: "conv-A")
        #expect(sessionA !== sessionAReborn)
    }
}

/// A `ToolExecutor` that sleeps until either a long timeout elapses or the
/// surrounding task is cancelled. Signals via `awaitFirstCall()` once
/// invocation has actually started so tests can synchronize cancellation
/// with the in-flight `Task.sleep`.
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
