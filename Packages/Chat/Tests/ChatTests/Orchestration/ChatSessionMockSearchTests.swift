import Core
import Foundation
import Testing

@testable import Chat

@Suite("ChatSession mock search")
struct ChatSessionMockSearchTests {

    private static let canned = WebSearchResult(
        findings: "Canned findings about Mars.",
        sources: [
            SourceCitation(id: "https://nasa.gov/x#0", title: "NASA", url: URL(string: "https://nasa.gov/x")!),
            SourceCitation(id: "https://space.com/y#1", title: "Space", url: URL(string: "https://space.com/y")!),
        ],
        searchSuggestionsHTML: "<html>suggest</html>"
    )

    private struct Setup {
        let messageRepo: GRDBMessageRepository
        let toolCallRepo: GRDBToolCallRepository
        let provider: FakeLLMProvider
        let fulfiller: FakeWebSearchFulfiller?
        let model: LLMModel
        let session: ChatSession
    }

    private func makeSetup(
        scripts: [[LLMStreamEvent]],
        askBeforeSearching: Bool = true,
        fulfiller: FakeWebSearchFulfiller? = FakeWebSearchFulfiller(result: canned)
    ) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

        let model = LLMModel(
            id: "mock-model-1",
            displayName: "Mock Model",
            maxContextTokens: 8_192,
            searchBackend: NativeWebSearch.mockBackendValue
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
            askBeforeSearching: askBeforeSearching,
            webSearchFulfiller: fulfiller
        )
        return Setup(
            messageRepo: messageRepo, toolCallRepo: toolCallRepo,
            provider: provider, fulfiller: fulfiller, model: model, session: session
        )
    }

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
            .messageStart(id: "m1", model: "mock-model-1"),
            .toolUse(
                index: 0, id: "tc-search", name: NativeWebSearch.proposalToolName,
                input: .object(["query": .string("mars rover news"), "reason": .string("current events")])
            , signature: nil),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ]
    }

    private func groundedAnswerScript() -> [LLMStreamEvent] {
        [
            .messageStart(id: "m2", model: "mock-model-1"),
            .textDelta(index: 0, text: "Here is what the search found."),
            .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
        ]
    }

    /// Bootstrap uses this literal because NativeWebSearch is internal to Chat.
    @Test("mock backend value is the literal the bootstrap seed uses")
    func mockBackendValueIsDebug() {
        #expect(NativeWebSearch.mockBackendValue == "debug")
    }

    @Test("gate ON: approving fulfills the search in-process and lands canned sources on the answer")
    func approveFulfillsInProcess() async throws {
        let setup = try await makeSetup(scripts: [proposalScript(), groundedAnswerScript()])

        let stream = await setup.session.send(text: "what's new on mars?", model: setup.model)
        let events = await collectResolving(stream, session: setup.session, approve: true)
        await setup.session.waitUntilFinished()

        let parked = events.filter { if case .toolCallAwaitingConfirmation = $0 { return true }; return false }
        #expect(parked.count == 1)

        #expect(await setup.fulfiller?.capturedQueries() == ["mars rover news"])

        let proposalCall = try #require(await setup.toolCallRepo.fetch(id: "tc-search"))
        #expect(proposalCall.status == .success)
        let requests = await setup.provider.capturedRequests()
        #expect(requests.count == 2)
        #expect(!requests.contains { $0.tools.map(\.name).contains(NativeWebSearch.sentinelToolName) })
        #expect(!requests[1].tools.map(\.name).contains(NativeWebSearch.proposalToolName))

        let messages = try await setup.messageRepo.fetchAll(conversationId: "conv-1")
        let toolRow = messages.first { $0.role == .tool && $0.toolCallId == "tc-search" }
        #expect(toolRow?.content == Self.canned.findings)

        let assistant = messages.last { $0.role == .assistant }
        #expect(assistant?.content == "Here is what the search found.")
        #expect(assistant?.attachments?.sources.count == Self.canned.sources.count)
        #expect(assistant?.attachments?.searchSuggestionsHTML == Self.canned.searchSuggestionsHTML)
        // The fulfiller supplies query metadata; this answer emits no searchStarted event.
        #expect(assistant?.attachments?.searchQuery == "mars rover news")
        #expect(assistant?.attachments?.searchSystem == "Debug (mock)")
    }

    @Test("gate ON: skipping writes a declined result, never calls the fulfiller, attaches no sources")
    func skipDoesNotFulfill() async throws {
        let setup = try await makeSetup(scripts: [
            proposalScript(),
            [
                .messageStart(id: "m2", model: "mock-model-1"),
                .textDelta(index: 0, text: "From what I know already…"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
            ],
        ])

        let stream = await setup.session.send(text: "what's new on mars?", model: setup.model)
        _ = await collectResolving(stream, session: setup.session, approve: false)
        await setup.session.waitUntilFinished()

        #expect(await setup.fulfiller?.capturedQueries().isEmpty == true)
        let proposalCall = try #require(await setup.toolCallRepo.fetch(id: "tc-search"))
        #expect(proposalCall.status == .cancelled)
        let messages = try await setup.messageRepo.fetchAll(conversationId: "conv-1")
        let assistant = messages.last { $0.role == .assistant }
        #expect(assistant?.content == "From what I know already…")
        #expect(assistant?.attachments?.sources.isEmpty ?? true)
    }

    @Test("gate OFF: the search auto-fulfills with no confirm prompt, sources still attach")
    func gateOffAutoFulfills() async throws {
        let setup = try await makeSetup(
            scripts: [proposalScript(), groundedAnswerScript()],
            askBeforeSearching: false
        )

        let stream = await setup.session.send(text: "what's new?", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        #expect(!events.contains { if case .toolCallAwaitingConfirmation = $0 { return true }; return false })
        #expect(await setup.fulfiller?.capturedQueries() == ["mars rover news"])
        let messages = try await setup.messageRepo.fetchAll(conversationId: "conv-1")
        let assistant = messages.last { $0.role == .assistant }
        #expect(assistant?.attachments?.sources.count == Self.canned.sources.count)
    }

    @Test("a stashed mock result does not leak onto a later turn when the grounded turn errors")
    func stashDoesNotLeakAcrossTurnsOnError() async throws {
        let setup = try await makeSetup(scripts: [
            proposalScript(),
            // Fail before the stashed sources are drained.
            [
                .messageStart(id: "m2", model: "mock-model-1"),
                .error(.requestFailed("boom")),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m3", model: "mock-model-1"),
                .textDelta(index: 0, text: "Plain answer, no search."),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
            ],
        ])

        let stream1 = await setup.session.send(text: "what's new on mars?", model: setup.model)
        _ = await collectResolving(stream1, session: setup.session, approve: true)
        await setup.session.waitUntilFinished()

        let stream2 = await setup.session.send(text: "hello", model: setup.model)
        _ = await collect(stream2)
        await setup.session.waitUntilFinished()

        let messages = try await setup.messageRepo.fetchAll(conversationId: "conv-1")
        let lastAssistant = messages.last { $0.role == .assistant }
        #expect(lastAssistant?.content == "Plain answer, no search.")
        #expect(lastAssistant?.attachments?.sources.isEmpty ?? true)
    }

    @Test("no fulfiller wired: an approved mock search degrades to a declined result")
    func noFulfillerDegradesToDeclined() async throws {
        let setup = try await makeSetup(
            scripts: [
                proposalScript(),
                [
                    .messageStart(id: "m2", model: "mock-model-1"),
                    .textDelta(index: 0, text: "Answering without search."),
                    .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
                ],
            ],
            fulfiller: nil
        )

        let stream = await setup.session.send(text: "what's new on mars?", model: setup.model)
        _ = await collectResolving(stream, session: setup.session, approve: true)
        await setup.session.waitUntilFinished()

        let proposalCall = try #require(await setup.toolCallRepo.fetch(id: "tc-search"))
        #expect(proposalCall.status == .cancelled)
        let messages = try await setup.messageRepo.fetchAll(conversationId: "conv-1")
        #expect(messages.last { $0.role == .assistant }?.attachments?.sources.isEmpty ?? true)
    }
}
