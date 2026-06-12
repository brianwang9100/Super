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
                .toolUse(index: 0, id: "tc-a", name: toolID, input: .object([:]), signature: nil),
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

        // Start A first and wait for its tool to actually run before starting
        // B. The `FakeLLMProvider` script queue is shared — both sessions race
        // to consume it — and the two scripts have *different shapes* (A
        // requests a tool, B replies with text). Without this sequencing, B
        // can win the race, consume A's tool-call script, enter a tool loop,
        // and emit an unscripted third `stream(...)` call that fires after the
        // test ends — observed as a `STRAY-STREAM` leak in CI/local runs.
        // `awaitFirstCall()` is reached only after A has consumed script #1
        // and dispatched into the tool, so by then it's safe to start B.
        let streamA = await sessionA.send(text: "kick A", model: setup.model)
        async let eventsA: [ChatEvent] = self.collect(streamA)
        await sleepingExecutor.awaitFirstCall()

        let streamB = await sessionB.send(text: "kick B", model: setup.model)
        async let eventsB: [ChatEvent] = self.collect(streamB)

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

    @Test func setUserPersonalizationFansOutToExistingSession() async throws {
        // `store.setUserPersonalization(_:)` must reach already-created
        // sessions so a long-running conversation picks up a Settings
        // edit on its next turn — testing the actual fan-out loop rather
        // than just the session-level setter is what protects against a
        // future refactor that drops the loop.
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
        // The leading block carries the personalization under its
        // `## User personalization` section header — assert on substring
        // since the rendered block wraps the value in headings/spacing.
        if case .text(let body) = request?.messages.first?.content.first {
            #expect(body.contains("## User personalization"))
            #expect(body.contains("Always answer in haiku."))
        } else {
            Issue.record("expected leading .system row carrying personalization, got \(String(describing: request?.messages.first?.content))")
        }
    }

    @Test func setAutoCompactPolicyTriggersAutoCompactionOnExistingSession() async throws {
        // The store-level fan-out must reach already-created sessions, so a
        // long-running conversation picks up a slider/toggle change on its
        // next turn. End-to-end signal: bootstrap the store with auto-
        // compaction disabled, seed enough history to summarize, flip the
        // policy via `setAutoCompactPolicy(...)`, then send one more message
        // and assert the provider was hit for the summarization turn — the
        // only side effect that proves the new policy actually reached the
        // existing session.
        let setup = try await makeStore(scripts: [
            // Summarization turn fires first (auto-compaction runs at the
            // top of the turn loop).
            [
                .messageStart(id: "sum", model: "fake-model-1"),
                .textDelta(index: 0, text: "Summary of the older turns."),
                .messageComplete(usage: TokenUsage(inputTokens: 8, outputTokens: 4)),
            ],
            // Then the actual assistant reply.
            [
                .messageStart(id: "reply", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 4, outputTokens: 1)),
            ],
        ])

        // Seed 12 messages so the compactor has something to summarize once
        // the policy flips on (keepMostRecent defaults to 4 → 8 messages
        // are eligible for summarization).
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
        // Flip auto-compaction on with a near-zero threshold so the seeded
        // history is guaranteed to be "over threshold."
        await setup.store.setAutoCompactPolicy(enabled: true, threshold: 0.0001)

        let stream = await session.send(text: "next prompt", model: setup.model)
        let events = await self.collect(stream)
        await session.waitUntilFinished()

        let compactionStarted = events.contains {
            if case .compactionStarted = $0 { return true } else { return false }
        }
        #expect(compactionStarted, "policy fan-out failed to reach the existing session")

        // Two provider calls: summarization + the actual turn.
        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)
    }

    @Test func setAutoCompactPolicyIsInheritedBySessionsCreatedAfterTheCall() async throws {
        // Sessions created *after* a store-level policy change must seed
        // with the new values, not the construction-time defaults. Without
        // this, every newly-opened chat would silently revert to the
        // boot-time policy until app restart.
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

        // Flip policy BEFORE any session for conv-B exists.
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
        // Sessions created *after* a store-level
        // `setUserPersonalization(...)` must start with the new value,
        // not the construction-time default. Otherwise the user's
        // just-saved text would only affect conversations whose sessions
        // existed at save time — every subsequent "new chat" would
        // silently revert to the value the store was bootstrapped with.
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

    /// A force-quit/crash mid-turn strands tool calls at non-terminal
    /// statuses with no result rows — `recoverInterruptedToolCalls()` must
    /// resolve exactly those on launch: status → `.failed` + `completedAt`,
    /// and a role-`.tool` result row when (and only when) none exists.
    /// Regression for audit P0-2's missing "recovery sweep".
    @Test func recoverySweepResolvesStrandedToolCalls() async throws {
        let setup = try await makeStore()
        let messageRepo = GRDBMessageRepository(database: setup.database)
        let toolCallRepo = GRDBToolCallRepository(database: setup.database)

        // Parent assistant rows so the tool-call FKs resolve.
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

        // Three stranded shapes (no result row): pending / executing /
        // awaitingConfirmation — the second one in a different conversation.
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
        // Terminal row — must be untouched.
        try await seedToolCall(
            in: setup.database, id: "tc-done", messageId: "m-A",
            conversationId: "conv-A", status: .success, clock: setup.clock
        )
        // Non-terminal but its result row already landed (crash between the
        // message write and the status update) — status fixed, no duplicate row.
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

        // Stranded calls landed .failed with completedAt.
        for id in ["tc-pending", "tc-confirm", "tc-executing", "tc-rowed"] {
            let record = try #require(await toolCallRepo.fetch(id: id))
            #expect(record.status == .failed, "expected \(id) to be .failed")
            #expect(record.completedAt != nil)
        }
        // Terminal row untouched.
        let done = try #require(await toolCallRepo.fetch(id: "tc-done"))
        #expect(done.status == .success)
        #expect(done.completedAt == nil)

        // Exactly one role-.tool row per call — synthesized for the three
        // stranded ones, the pre-existing one not duplicated.
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
