import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `BibleAnnotateDispatcher` — the Chat-side observer that
/// runs one-off `bible.annotate` turns in response to a Bible UI tap.
///
/// Each test scripts a `FakeLLMProvider` to emit a `bible.annotate`
/// tool call (or not, for failure-path coverage), registers a
/// `FakeToolExecutor` under `"bible.annotate"` to stand in for the
/// real `AnnotateBibleTool` (Chat tests can't import the Bible
/// package), publishes a `bibleAnnotateRequested` envelope on a real
/// `SuperEventBus`, and asserts on the completion envelope plus the
/// chat DB's post-dispatch state.
@Suite("BibleAnnotateDispatcher")
@MainActor
struct BibleAnnotateDispatcherTests {

    /// Wires the fixture once per test. Producing the dispatcher takes
    /// many pieces (chat DB + every repository + provider registry +
    /// tool registry + compactor + model config), so doing it inline
    /// in each `@Test` would drown the assertions.
    private struct Setup {
        let database: ChatDatabase
        let conversationRepo: GRDBConversationRepository
        let modelConfigRepo: GRDBModelConfigurationRepository
        let provider: FakeLLMProvider
        let bus: SuperEventBus
        let toolExecutor: FakeToolExecutor
        let dispatcher: BibleAnnotateDispatcher
    }

    private func makeSetup(
        scripts: [[LLMStreamEvent]],
        seedSelectedModel: Bool = true
    ) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let conversationRepo = GRDBConversationRepository(database: database)
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let modelConfigRepo = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)

        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        for script in scripts { await provider.enqueue(script) }

        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        try await llmRegistry.setActive(id: provider.id)

        if seedSelectedModel {
            // Seed a selected model row matching the fake provider's
            // model id so `resolveActiveModel` returns the fake's model.
            try await modelConfigRepo.save(
                ModelConfigurationRecord(
                    id: "cfg-1",
                    name: "Fake",
                    baseURL: URL(string: "https://example.com/v1")!,
                    apiKeyRef: "ref",
                    modelId: model.id,
                    createdAt: clock.now(),
                    isSelected: true
                )
            )
        }

        let toolExecutor = FakeToolExecutor(toolID: "bible.annotate")
        await toolExecutor.setResult(ToolResult(
            toolID: "bible.annotate",
            content: "Wrote 2 annotations for the target.",
            isError: false,
            artifacts: [
                ToolResult.Artifact(type: "annotation", id: "ann-1"),
                ToolResult.Artifact(type: "annotation", id: "ann-2"),
            ]
        ))
        let toolRegistry = ToolRegistry()
        await toolRegistry.register(ToolRegistration(
            tool: LLMTool(
                id: "bible.annotate",
                name: "bible.annotate",
                description: "stub",
                category: .mutation,
                parameters: [],
                appletId: "bible"
            ),
            execution: .local(toolExecutor),
            isEnabled: true
        ))

        let compactor = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGen
        )

        let bus = SuperEventBus()
        let dispatcher = BibleAnnotateDispatcher(
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            modelConfigurationRepository: modelConfigRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            compactor: compactor,
            clock: clock,
            idGenerator: idGen
        )
        await dispatcher.attach(to: bus)

        return Setup(
            database: database,
            conversationRepo: conversationRepo,
            modelConfigRepo: modelConfigRepo,
            provider: provider,
            bus: bus,
            toolExecutor: toolExecutor,
            dispatcher: dispatcher
        )
    }

    private func reference(
        id: String = "req-1",
        kind: String = "verseRange",
        sourceID: String = "verse:ROM:8:28:30"
    ) -> RecordReference {
        RecordReference(
            appletID: "bible",
            kind: kind,
            sourceID: sourceID,
            displayLabel: "Romans 8:28-30 (WEB)",
            citation: "Romans 8:28-30 (WEB)",
            snapshot: "All things work together for good...",
            id: id
        )
    }

    /// Drain `stream` until the matching `bibleAnnotateCompleted`
    /// envelope arrives. The caller is responsible for subscribing
    /// (`await bus.events()`) before publishing the request — that
    /// ensures the dispatcher's later completion event is delivered
    /// on this iterator instead of being missed.
    private func drainUntilCompletion(
        requestId: String,
        stream: AsyncStream<SuperEvent>
    ) async -> BibleAnnotateResult {
        for await event in stream {
            if case .bibleAnnotateCompleted(let id, let result) = event,
               id == requestId {
                return result
            }
        }
        return .failure(message: "stream closed without completion")
    }

    @Test("a scripted tool call succeeds and the transient conversation is hard-deleted")
    func happyPathSucceedsAndCleansUp() async throws {
        // Script: turn 1 — the model issues a tool call to bible.annotate;
        // turn 2 — the model emits a short final text and ends.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:])),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "Done."),
                .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
            ],
        ])

        let request = reference()
        // Subscribe to the bus *before* publishing the request so the
        // completion the dispatcher fires after its turn is guaranteed
        // to land in the iterator below.
        let stream = await setup.bus.events()
        await setup.bus.publish(.bibleAnnotateRequested(reference: request))
        let result = await drainUntilCompletion(requestId: request.id, stream: stream)

        #expect(result == .success(annotationCount: 2))

        // Tool was invoked exactly once with the dispatcher's prompt.
        #expect(await setup.toolExecutor.executionCount() == 1)

        // Transient conversation row is gone after the dispatch.
        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    @Test("a tool call that returns zero artifacts is reported as success, not failure")
    func zeroArtifactsIsStillSuccess() async throws {
        // Regression for the doc-code contract on `BibleAnnotateResult`:
        // `.success(annotationCount: 0)` is a valid outcome when the
        // tool was called but produced no new rows (e.g., the
        // `replace` cleared an already-present set without inserting).
        // Distinct from "the model never called the tool" — that's
        // still a failure.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:])),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "Done."),
                .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
            ],
        ])
        // Override the default 2-artifact result with a no-artifact
        // success (mimics the "all rows already exist" cleared-replace
        // case the tool's `content` line uses).
        await setup.toolExecutor.setResult(ToolResult(
            toolID: "bible.annotate",
            content: "Cleared annotations for the target.",
            isError: false,
            artifacts: []
        ))

        let request = reference(id: "req-zero")
        let stream = await setup.bus.events()
        await setup.bus.publish(.bibleAnnotateRequested(reference: request))
        let result = await drainUntilCompletion(requestId: request.id, stream: stream)

        #expect(result == .success(annotationCount: 0))
    }

    @Test("a model that never calls bible.annotate produces a failure with a clear message")
    func textOnlyTurnIsAFailure() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "Sure thing!"),
                .messageComplete(usage: TokenUsage(inputTokens: 4, outputTokens: 2)),
            ],
        ])

        let request = reference(id: "req-2")
        let stream = await setup.bus.events()
        await setup.bus.publish(.bibleAnnotateRequested(reference: request))
        let result = await drainUntilCompletion(requestId: request.id, stream: stream)

        guard case .failure(let message) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        #expect(message.contains("didn't call bible.annotate"))

        // Even on failure the transient conversation is cleaned up.
        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    @Test("an LLM error mid-stream becomes a failure carrying the error description")
    func providerErrorBecomesFailure() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .error(LLMError.providerError(code: "500", message: "boom")),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])

        let request = reference(id: "req-3")
        let stream = await setup.bus.events()
        await setup.bus.publish(.bibleAnnotateRequested(reference: request))
        let result = await drainUntilCompletion(requestId: request.id, stream: stream)

        guard case .failure = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    @Test("with no model selected the dispatcher fails fast before opening a conversation")
    func missingSelectedModelFailsFast() async throws {
        // Skip seeding — the dispatcher hits `resolveActiveModel`
        // before opening the conversation and bails on `.noSelectedModel`.
        let setup = try await makeSetup(scripts: [], seedSelectedModel: false)

        let request = reference(id: "req-4")
        let stream = await setup.bus.events()
        await setup.bus.publish(.bibleAnnotateRequested(reference: request))
        let result = await drainUntilCompletion(requestId: request.id, stream: stream)

        guard case .failure(let message) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        #expect(message.contains("No model is selected"))

        // No transient conversation was created — nothing to clean up.
        // Use the first generated id ("id-1") because the model-resolve
        // step bails before the id generator is consumed for the row.
        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }
}
