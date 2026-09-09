import Core
import Foundation
import Testing
import os
@testable import Chat

/// Ensures asynchronous model readiness and context resolve before either
/// compaction gate; unavailable selection never turns into another provider.
@Suite
struct ChatSessionModelResolutionTests {
    private static let placeholder = LLMModel(
        id: "private-cloud-compute", displayName: "PCC fixture", maxContextTokens: 50
    )
    private static let resolved = LLMModel(
        id: "private-cloud-compute", displayName: "PCC fixture", maxContextTokens: 100_000
    )
    private static let unavailable = LLMError.providerError(
        code: "pcc_quota_limit_reached", message: "Usage limit fixture"
    )

    @Test
    func autoCompactionUsesResolvedContextInsteadOfSavedPlaceholder() async throws {
        let setup = try await makeSetup(result: .success(Self.resolved))
        let events = await collect(await setup.session.send(text: "next message", model: Self.placeholder))
        await setup.session.waitUntilFinished()
        #expect(!events.contains(.compactionStarted))
        #expect(events.contains(.modelResolved(SelectableModel(recordId: setup.provider.id, model: Self.resolved))))
        #expect(setup.provider.operations == ["resolve", "stream:100000"])
        #expect(await setup.provider.engine.capturedRequests().count == 1)
        #expect(try await setup.checkpoints.liveCheckpoint(for: setup.conversationID) == nil)
    }

    @Test
    func manualCompactionChecksItsRatioUsingResolvedContext() async throws {
        let setup = try await makeSetup(result: .success(Self.resolved))
        let events = await collect(await setup.session.compact(model: Self.placeholder))
        await setup.session.waitUntilFinished()
        #expect(!events.contains(.compactionStarted))
        #expect(events.contains {
            if case .error(.requestFailed(let message)) = $0 { return message.contains("too short to compact") }
            return false
        })
        #expect(setup.provider.operations == ["resolve"])
        #expect(await setup.provider.engine.capturedRequests().isEmpty)
        #expect(try await setup.checkpoints.liveCheckpoint(for: setup.conversationID) == nil)
    }

    @Test(arguments: EntryPoint.allCases)
    func failedResolutionKeepsSelectedIdentityAndDoesNotCompact(entry: EntryPoint) async throws {
        let setup = try await makeSetup(result: .failure(Self.unavailable))
        let stream: AsyncStream<ChatEvent>
        switch entry {
        case .send: stream = await setup.session.send(text: "next message", model: Self.placeholder)
        case .retry: stream = await setup.session.retry(model: Self.placeholder)
        case .compact: stream = await setup.session.compact(model: Self.placeholder)
        }
        let events = await collect(stream)
        await setup.session.waitUntilFinished()
        #expect(events.contains(.error(Self.unavailable)))
        #expect(!events.contains { if case .modelResolved = $0 { return true }; return false })
        #expect(!events.contains(.compactionStarted))
        #expect(setup.provider.operations == ["resolve"])
        #expect(await setup.registry.activeID() == setup.provider.id)
        #expect(await setup.provider.engine.capturedRequests().isEmpty)
        #expect(try await setup.checkpoints.liveCheckpoint(for: setup.conversationID) == nil)
    }

    @Test
    func standaloneCompactorResolvesBeforeRequestingASummary() async throws {
        let setup = try await makeSetup(result: .failure(Self.unavailable))
        let messages = try await setup.messages.fetchAll(conversationId: setup.conversationID)
        await #expect(throws: Self.unavailable) {
            try await setup.compactor.compact(
                conversationId: setup.conversationID, messages: messages, toolCalls: [],
                priorCheckpoint: nil, model: Self.placeholder
            )
        }
        #expect(setup.provider.operations == ["resolve"])
        #expect(await setup.provider.engine.capturedRequests().isEmpty)
        #expect(try await setup.checkpoints.liveCheckpoint(for: setup.conversationID) == nil)
    }

    private func makeSetup(result: Result<LLMModel, LLMError>) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let messages = GRDBMessageRepository(database: database)
        let checkpoints = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let ids = DeterministicIDGenerator(prefix: "resolution-")
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)
        let engine = FakeLLMProvider(id: "saved-pcc-row", model: Self.placeholder)
        // Two responses make an unintended compaction observable as an extra
        // request/assertion failure, rather than exhausting the strict fixture.
        for index in 0..<2 {
            await engine.enqueue([
                .messageStart(id: "response-\(index)", model: Self.placeholder.id),
                .textDelta(index: 0, text: "Fixture response"),
                .messageComplete(usage: .init(inputTokens: 1, outputTokens: 1)),
            ])
        }
        let provider = ResolvingModelProvider(engine: engine, result: result)
        let registry = LLMProviderRegistry()
        await registry.register(provider)
        let compactor = OrchestrationFixtures.makeCompactor(
            database: database, llmRegistry: registry, clock: clock, idGenerator: ids
        )
        for index in 0..<6 {
            for role in [MessageRole.user, .assistant] {
                try await messages.save(MessageRecord(
                    id: "history-\(index)-\(role.rawValue)", conversationId: conversation.id,
                    role: role, content: "Short history fixture with several words.", createdAt: clock.now()
                ))
            }
        }
        let session = ChatSession(
            conversationId: conversation.id, messageRepository: messages,
            toolCallRepository: GRDBToolCallRepository(database: database), checkpointRepository: checkpoints,
            llmProviderRegistry: registry, toolRegistry: ToolRegistry(), compactor: compactor,
            clock: clock, idGenerator: ids, autoCompactThreshold: 0.5, manualCompactMinThreshold: 0.5
        )
        return Setup(
            conversationID: conversation.id, messages: messages, checkpoints: checkpoints,
            registry: registry, provider: provider, compactor: compactor, session: session
        )
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    enum EntryPoint: CaseIterable, Sendable { case send, retry, compact }

    private struct Setup {
        let conversationID: String
        let messages: GRDBMessageRepository
        let checkpoints: GRDBCompactionCheckpointRepository
        let registry: LLMProviderRegistry
        let provider: ResolvingModelProvider
        let compactor: Compactor
        let session: ChatSession
    }
}

/// Wraps the strict stream fixture with a deterministic metadata-resolution seam.
private struct ResolvingModelProvider: LLMProvider {
    let engine: FakeLLMProvider
    let result: Result<LLMModel, LLMError>
    private let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])

    var id: String { engine.id }
    var displayName: String { engine.displayName }
    var supportedModels: [LLMModel] { engine.supportedModels }
    var operations: [String] { recorded.withLock { $0 } }

    init(engine: FakeLLMProvider, result: Result<LLMModel, LLMError>) {
        self.engine = engine
        self.result = result
    }

    func resolveModel(_ model: LLMModel) async throws(LLMError) -> LLMModel {
        recorded.withLock { $0.append("resolve") }
        switch result {
        case .success(let resolved): return resolved
        case .failure(let error): throw error
        }
    }

    func stream(
        messages: [LLMMessage], model: LLMModel, tools: [LLMTool], temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        recorded.withLock { $0.append("stream:\(model.maxContextTokens)") }
        return engine.stream(messages: messages, model: model, tools: tools, temperature: temperature)
    }
}
