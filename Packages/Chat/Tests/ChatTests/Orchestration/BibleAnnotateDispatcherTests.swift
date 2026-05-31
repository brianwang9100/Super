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
        registerProvider: Bool = true,
        seedSelectedModel: Bool = true,
        selectedModelId: String? = nil
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
        if registerProvider {
            await llmRegistry.register(provider)
            try await llmRegistry.setActive(id: provider.id)
        }

        if seedSelectedModel {
            // Seed a selected model row. By default its `modelId` matches
            // the fake provider's model; `selectedModelId` overrides it to
            // simulate a selection that's desynced from the active provider
            // (e.g. Apple Intelligence picked on a device where AFM didn't
            // register). The dispatcher resolves its model from the active
            // provider, so the desynced row must be ignored, not fatal.
            try await modelConfigRepo.save(
                ModelConfigurationRecord(
                    id: "cfg-1",
                    name: "Fake",
                    baseURL: URL(string: "https://example.com/v1")!,
                    apiKeyRef: "ref",
                    modelId: selectedModelId ?? model.id,
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

    @Test("with no provider registered the dispatcher fails fast before opening a conversation")
    func noActiveProviderFailsFast() async throws {
        // No provider registered → `llmProviderRegistry.active()` is nil,
        // so the dispatcher hits `resolveActiveModel` before opening the
        // conversation and bails on `.noActiveProvider`.
        let setup = try await makeSetup(
            scripts: [],
            registerProvider: false,
            seedSelectedModel: false
        )

        let request = reference(id: "req-4")
        let stream = await setup.bus.events()
        await setup.bus.publish(.bibleAnnotateRequested(reference: request))
        let result = await drainUntilCompletion(requestId: request.id, stream: stream)

        guard case .failure(let message) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        #expect(message.contains("No LLM provider is configured"))

        // Guards the ordering invariant: `resolveActiveModel` must throw
        // *before* `dispatch` saves the conversation. The deterministic
        // generator names the first (unconsumed) id "id-1", so a regression
        // that saved the row before resolving — and skipped cleanup on the
        // throw path — would leave "id-1" behind and fail this assertion.
        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    @Test("a selection desynced from the active provider resolves the active provider's model, not a failure")
    func desyncedSelectionUsesActiveProviderModel() async throws {
        // Regression: the selected config row points at Apple Intelligence
        // ("system-default") but AFM never registered, so the active
        // provider is a different one. The dispatcher must run the turn
        // against the active provider's model — the same model normal chat
        // sessions use — instead of hard-failing because the persisted
        // selection isn't in the active provider's `supportedModels`.
        let setup = try await makeSetup(
            scripts: [
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
            ],
            selectedModelId: "system-default"
        )

        let request = reference(id: "req-desync")
        let stream = await setup.bus.events()
        await setup.bus.publish(.bibleAnnotateRequested(reference: request))
        let result = await drainUntilCompletion(requestId: request.id, stream: stream)

        #expect(result == .success(annotationCount: 2))
        #expect(await setup.toolExecutor.executionCount() == 1)

        // The turn ran against the *active provider's* model
        // ("fake-model-1"), not the desynced selected row's
        // "system-default" — this is the assertion that makes the test a
        // real regression guard rather than a happy-path duplicate. Every
        // captured request carries the active provider's model id.
        let capturedModels = await setup.provider.capturedRequests().map(\.modelID)
        #expect(!capturedModels.isEmpty)
        #expect(capturedModels.allSatisfy { $0 == "fake-model-1" })

        // Transient conversation is hard-deleted like every other dispatch.
        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    // MARK: - Per-scope section guidance

    // `prompt(for:)` is a pure static function, so these exercise it
    // directly — no bus, session, or model needed. They're the
    // regression guard for the per-scope steer: before the dispatcher
    // carried `ANNOTATIONS.md` §1's sections, every scope got the same
    // generic prompt and these section keywords were absent.

    @Test("a book request's prompt names the book-level sections to cover")
    func bookPromptNamesBookSections() {
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(kind: "book", sourceID: "book:ROM")
        )
        #expect(prompt.contains("this book"))
        #expect(prompt.contains("historical context"))
        #expect(prompt.contains("summary"))
    }

    @Test("a chapter request's prompt names the chapter-level sections to cover")
    func chapterPromptNamesChapterSections() {
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(kind: "chapter", sourceID: "chapter:ROM:8")
        )
        #expect(prompt.contains("this chapter"))
        #expect(prompt.contains("summary"))
        #expect(prompt.contains("outline"))
    }

    @Test("a verse-range request's prompt names the verse-level sections to cover")
    func versePromptNamesVerseSections() {
        // Note the kind is "verseRange", not "verse" — the Bible UI
        // stamps the former, while the tool's `target` is "verse".
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(kind: "verseRange", sourceID: "verse:ROM:8:28:30")
        )
        #expect(prompt.contains("this verse range"))
        #expect(prompt.contains("historical context"))
        #expect(prompt.contains("clarification"))
        #expect(prompt.contains("cross-reference"))
    }

    @Test("an unrecognised kind falls back to the generic prompt with no scope line")
    func unknownKindFallsBackToGenericPrompt() {
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(kind: "mystery", sourceID: "mystery:ROM")
        )
        // No per-scope steer leaked in...
        #expect(!prompt.contains("aim to cover"))
        #expect(BibleAnnotateDispatcher.sectionGuidance(forKind: "mystery") == nil)
        // ...the target-identification block still names the target so the
        // model can still produce valid arguments (guards against the
        // first paragraph being dropped on the fallback path)...
        #expect(prompt.contains("Target kind: mystery"))
        #expect(prompt.contains("Reference id: mystery:ROM"))
        #expect(prompt.contains("Romans 8:28-30 (WEB)"))
        // ...and the structural instruction to call the tool once stands.
        #expect(prompt.contains("Call `bible.annotate` once"))
    }

    @Test("the dispatcher briefing keeps its load-bearing one-tool mandate")
    func briefingKeepsToolMandate() {
        // The briefing is steering the model, not just documentation:
        // guard the invariants a future edit could silently blank — the
        // single `bible.annotate` call and the no-other-tool constraint.
        let briefing = BibleAnnotateDispatcher.dispatcherBriefing
        #expect(briefing.contains("`bible.annotate`"))
        #expect(briefing.contains("exactly once"))
        #expect(briefing.contains("do not call any other tool"))
    }
}
