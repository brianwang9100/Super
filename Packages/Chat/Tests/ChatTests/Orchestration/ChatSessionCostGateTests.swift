import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ChatSession`'s native web-search cost gate: the
/// `request_web_search` proposal → `.awaitingConfirmation` → approve/skip
/// flow, the `__native_web_search__` sentinel wiring it produces, and the
/// gate-OFF / non-native short-circuits. Uses the strict `FakeLLMProvider`
/// (never a live endpoint) and resolves the gate inline on the
/// `.toolCallAwaitingConfirmation` event so there is no `Task.sleep` polling.
@Suite("ChatSession cost gate")
struct ChatSessionCostGateTests {

    private struct Setup {
        let messageRepo: GRDBMessageRepository
        let toolCallRepo: GRDBToolCallRepository
        let provider: FakeLLMProvider
        let model: LLMModel
        let session: ChatSession
    }

    /// Build a session whose active model opts into native search.
    /// `searchBackend` defaults to `"native"`; pass `nil` for the
    /// non-native control.
    private func makeSetup(
        scripts: [[LLMStreamEvent]],
        askBeforeSearching: Bool = true,
        searchBackend: String? = "native"
    ) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

        let model = LLMModel(
            id: "native-model-1",
            displayName: "Native Model",
            maxContextTokens: 8_192,
            searchBackend: searchBackend
        )
        let provider = FakeLLMProvider(model: model)
        for script in scripts { await provider.enqueue(script) }
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
            autoCompactEnabled: false,
            askBeforeSearching: askBeforeSearching
        )
        return Setup(
            messageRepo: messageRepo, toolCallRepo: toolCallRepo,
            provider: provider, model: model, session: session
        )
    }

    /// Drain the turn stream, resolving the first parked search proposal
    /// inline (approve or skip) so the suspended turn re-issues. Because the
    /// confirm/skip resumes the same turn, its later events flow back through
    /// this same loop — no separate synchronization needed.
    private func collectResolving(
        _ stream: AsyncStream<ChatEvent>,
        session: ChatSession,
        approve: Bool
    ) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream {
            events.append(event)
            if case .toolCallAwaitingConfirmation(let record) = event {
                if approve {
                    await session.confirmToolCall(id: record.id)
                } else {
                    await session.skipToolCall(id: record.id)
                }
            }
        }
        return events
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func proposalScript() -> [LLMStreamEvent] {
        [
            .messageStart(id: "m1", model: "native-model-1"),
            .toolUse(
                index: 0, id: "tc-search", name: NativeWebSearch.proposalToolName,
                input: .object(["query": .string("mars rover news"), "reason": .string("current events")])
            , signature: nil),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ]
    }

    @Test("gate ON: a proposal parks, approval re-issues the turn with the sentinel")
    func approveRunsSearch() async throws {
        let setup = try await makeSetup(scripts: [
            proposalScript(),
            // Re-issued turn after approval: the grounded answer + a citation.
            [
                .messageStart(id: "m2", model: "native-model-1"),
                .searchStarted(query: "mars rover news"),
                .textDelta(index: 0, text: "Here is what I found."),
                .citations([SourceCitation(
                    id: "https://example.com/a#0", title: "A", url: URL(string: "https://example.com/a")!
                )]),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
            ],
        ])

        let stream = await setup.session.send(text: "what's new on mars?", model: setup.model)
        let events = await collectResolving(stream, session: setup.session, approve: true)
        await setup.session.waitUntilFinished()

        // The gate fired exactly once.
        let parked = events.filter { if case .toolCallAwaitingConfirmation = $0 { return true }; return false }
        #expect(parked.count == 1)

        // Turn 1 advertised the proposal, not the sentinel; turn 2 the reverse.
        let requests = await setup.provider.capturedRequests()
        #expect(requests.count == 2)
        let turn1 = requests[0].tools.map(\.name)
        let turn2 = requests[1].tools.map(\.name)
        #expect(turn1.contains(NativeWebSearch.proposalToolName))
        #expect(!turn1.contains(NativeWebSearch.sentinelToolName))
        #expect(turn2.contains(NativeWebSearch.sentinelToolName))
        #expect(!turn2.contains(NativeWebSearch.proposalToolName))

        // The proposal resolved to success and the answer + source persisted.
        let proposalCall = try #require(await setup.toolCallRepo.fetch(id: "tc-search"))
        #expect(proposalCall.status == .success)
        let messages = try await setup.messageRepo.fetchAll(conversationId: "conv-1")
        let assistant = messages.last { $0.role == .assistant }
        #expect(assistant?.content == "Here is what I found.")
        #expect(assistant?.attachments?.sources.count == 1)
        // Web-search cell metadata: query from `.searchStarted`, system from the
        // model's `"native"` backend.
        #expect(assistant?.attachments?.searchQuery == "mars rover news")
        #expect(assistant?.attachments?.searchSystem == "Native search")
    }

    @Test("gate ON: skipping answers without the sentinel and offers no further search")
    func skipAnswersWithoutSearch() async throws {
        let setup = try await makeSetup(scripts: [
            proposalScript(),
            // Re-issued turn after skip: a plain answer, no citations.
            [
                .messageStart(id: "m2", model: "native-model-1"),
                .textDelta(index: 0, text: "From what I know already…"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
            ],
        ])

        let stream = await setup.session.send(text: "what's new on mars?", model: setup.model)
        let events = await collectResolving(stream, session: setup.session, approve: false)
        await setup.session.waitUntilFinished()

        #expect(events.contains { if case .toolCallAwaitingConfirmation = $0 { return true }; return false })

        let requests = await setup.provider.capturedRequests()
        #expect(requests.count == 2)
        // The re-issued turn offers neither search tool — declined this loop.
        let turn2 = requests[1].tools.map(\.name)
        #expect(!turn2.contains(NativeWebSearch.sentinelToolName))
        #expect(!turn2.contains(NativeWebSearch.proposalToolName))

        // The proposal is recorded as cancelled, with a decline tool result row.
        let proposalCall = try #require(await setup.toolCallRepo.fetch(id: "tc-search"))
        #expect(proposalCall.status == .cancelled)
        let messages = try await setup.messageRepo.fetchAll(conversationId: "conv-1")
        let toolRow = messages.first { $0.role == .tool && $0.toolCallId == "tc-search" }
        #expect(toolRow != nil)
        #expect(messages.last { $0.role == .assistant }?.content == "From what I know already…")
    }

    @Test("gate OFF: the sentinel is present from turn 1, no proposal, no parking")
    func gateOffSearchesDirectly() async throws {
        let setup = try await makeSetup(
            scripts: [[
                .messageStart(id: "m1", model: "native-model-1"),
                .textDelta(index: 0, text: "Answer with sources."),
                .citations([SourceCitation(
                    id: "https://example.com/a#0", title: "A", url: URL(string: "https://example.com/a")!
                )]),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
            ]],
            askBeforeSearching: false
        )

        let stream = await setup.session.send(text: "what's new?", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        #expect(!events.contains { if case .toolCallAwaitingConfirmation = $0 { return true }; return false })
        let requests = await setup.provider.capturedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].tools.map(\.name).contains(NativeWebSearch.sentinelToolName))
        #expect(!requests[0].tools.map(\.name).contains(NativeWebSearch.proposalToolName))
    }

    @Test("non-native model: neither the proposal nor the sentinel is attached")
    func nonNativeModelNoSearchTools() async throws {
        let setup = try await makeSetup(
            scripts: [[
                .messageStart(id: "m1", model: "native-model-1"),
                .textDelta(index: 0, text: "plain answer"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ]],
            searchBackend: nil
        )

        let stream = await setup.session.send(text: "hi", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let requests = await setup.provider.capturedRequests()
        let names = requests[0].tools.map(\.name)
        #expect(!names.contains(NativeWebSearch.sentinelToolName))
        #expect(!names.contains(NativeWebSearch.proposalToolName))
    }

    @Test("cancelling while a proposal is parked ends the turn with .cancelled and leaves no orphan")
    func cancelWhileParked() async throws {
        // The follow-up turn proves the cancelled proposal didn't wedge the
        // conversation: a parked `tool_use` with no `tool_result` would be
        // replayed and rejected by the provider on the next turn.
        let setup = try await makeSetup(scripts: [
            proposalScript(),
            [
                .messageStart(id: "m2", model: "native-model-1"),
                .toolUse(
                    index: 0, id: "tc-search-2", name: NativeWebSearch.proposalToolName,
                    input: .object(["query": .string("q2"), "reason": .string("r2")])
                , signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m3", model: "native-model-1"),
                .textDelta(index: 0, text: "Answer."),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
            ],
        ])

        let stream = await setup.session.send(text: "what's new on mars?", model: setup.model)
        var events: [ChatEvent] = []
        for await event in stream {
            events.append(event)
            if case .toolCallAwaitingConfirmation = event {
                // Neither approve nor skip — cancel the turn instead.
                await setup.session.cancel()
            }
        }
        await setup.session.waitUntilFinished()

        // The parked continuation is resumed via the cancellation handler, so
        // the turn unwinds to a terminal `.error(.cancelled)` rather than
        // hanging forever.
        #expect(events.contains { if case .error(.cancelled) = $0 { return true }; return false })

        // Invariant: the cancelled proposal still got a terminal status + a
        // `.tool` result row, so its `tool_use` isn't orphaned.
        let proposalCall = try #require(await setup.toolCallRepo.fetch(id: "tc-search"))
        #expect(proposalCall.status == .cancelled)
        let afterCancel = try await setup.messageRepo.fetchAll(conversationId: "conv-1")
        #expect(afterCancel.contains { $0.role == .tool && $0.toolCallId == "tc-search" })

        // A fresh turn proceeds cleanly (skip the new proposal): no wedge.
        let stream2 = await setup.session.send(text: "and now?", model: setup.model)
        let events2 = await collectResolving(stream2, session: setup.session, approve: false)
        await setup.session.waitUntilFinished()
        #expect(events2.contains { if case .assistantMessageSaved = $0 { return true }; return false })
    }
}
