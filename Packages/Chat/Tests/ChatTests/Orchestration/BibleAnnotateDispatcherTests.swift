import Core
import Foundation
import Testing

@testable import Chat

@Suite("BibleAnnotateDispatcher")
@MainActor
struct BibleAnnotateDispatcherTests {

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
            // A persisted selection can outlive provider availability. The dispatcher
            // must resolve against the active provider even when this row disagrees.
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
        sourceID: String = "verse:ROM:8:28:30",
        snapshot: String = "All things work together for good..."
    ) -> RecordReference {
        RecordReference(
            appletID: "bible",
            kind: kind,
            sourceID: sourceID,
            displayLabel: "Romans 8:28-30 (WEB)",
            citation: "Romans 8:28-30 (WEB)",
            snapshot: snapshot,
            id: id
        )
    }

    /// Subscribe before publishing the request so its completion cannot be missed.
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

    @Test("foreground text is saved without creating a chat conversation")
    func foregroundTextIsSaved() async throws {
        let setup = try await makeSetup(scripts: [[
            .textDelta(index: 0, text: "First "),
            .textDelta(index: 0, text: "paragraph."),
            .messageComplete(usage: TokenUsage(inputTokens: 4, outputTokens: 2)),
        ],])
        let request = reference()
        let stream = await setup.bus.events()
        await setup.bus.publish(.bibleAnnotateRequested(reference: request))
        var progress: [String] = []
        for await event in stream {
            if case .bibleAnnotateProgress(let id, let text) = event, id == request.id {
                progress.append(text)
            }
            if case .bibleAnnotateCompleted(let id, let result) = event, id == request.id {
                #expect(result == .success(annotationCount: 2))
                break
            }
        }
        #expect(progress == ["First ", "First paragraph."])
        let inputs = await setup.toolExecutor.capturedInputs()
        #expect(inputs.count == 1)
        #expect(inputs.first?["summary"] == .string("First paragraph."))
        #expect(try await setup.conversationRepo.fetch(id: "id-1") == nil)
        #expect(try await setup.conversationRepo.listActive().isEmpty)
        #expect(try await setup.database.queue.read { db in
            try MessageRecord.fetchCount(db) == 0 && ToolCallRecord.fetchCount(db) == 0
        })
    }

    @Test("a scripted tool call succeeds and the transient conversation is hard-deleted")
    func happyPathSucceedsAndCleansUp() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "Done."),
                .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
            ],
        ])

        let request = reference()
        let result = await setup.dispatcher.generate(reference: request).asResult

        #expect(result == .success(annotationCount: 2))

        #expect(await setup.toolExecutor.executionCount() == 1)

        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    @Test("a tool call that returns zero artifacts is reported as success, not failure")
    func zeroArtifactsIsStillSuccess() async throws {
        // A called tool with zero new artifacts is successful; an uncalled tool is not.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "Done."),
                .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
            ],
        ])
        await setup.toolExecutor.setResult(ToolResult(
            toolID: "bible.annotate",
            content: "Cleared annotations for the target.",
            isError: false,
            artifacts: []
        ))

        let request = reference(id: "req-zero")
        let result = await setup.dispatcher.generate(reference: request).asResult

        #expect(result == .success(annotationCount: 0))
    }

    @Test("a successful tool call followed by a trailing stream error is still success")
    func successfulToolCallSurvivesTrailingError() async throws {
        // Once annotations are written, a trailing response error must not turn the
        // completed work into a failed bulk unit or a misleading error toast.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .error(LLMError.requestFailed("late boom")),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])

        let request = reference(id: "req-trailing-error")
        let result = await setup.dispatcher.generate(reference: request).asResult

        #expect(result == .success(annotationCount: 2))
        #expect(await setup.toolExecutor.executionCount() == 1)
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
        let result = await setup.dispatcher.generate(reference: request).asResult

        guard case .failure(let message) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        #expect(message.contains("didn't call bible.annotate"))

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
        let result = await setup.dispatcher.generate(reference: request).asResult

        guard case .failure = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    @Test("with no provider registered the dispatcher fails fast before opening a conversation")
    func noActiveProviderFailsFast() async throws {
        let setup = try await makeSetup(
            scripts: [],
            registerProvider: false,
            seedSelectedModel: false
        )

        let request = reference(id: "req-4")
        let result = await setup.dispatcher.generate(reference: request).asResult

        guard case .failure(let message) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        #expect(message.contains("No LLM provider is configured"))

        // Resolving the provider must precede saving a conversation. id-1 would
        // remain here if an early failure bypassed cleanup after saving.
        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    // MARK: - Failure classification

    // The bus result flattens failures; generate(reference:) exposes the richer
    // classification consumed by the bulk circuit breaker.

    private func classification(of outcome: BibleAnnotateOutcome) -> BibleAnnotateFailure? {
        guard case .failure(_, let classification) = outcome else { return nil }
        return classification
    }

    @Test("an unauthorized LLM error classifies as fatal auth")
    func unauthorizedIsFatalAuth() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .error(LLMError.unauthorized),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let outcome = await setup.dispatcher.generate(reference: reference(id: "req-auth"))
        #expect(classification(of: outcome) == .fatalAuth)
    }

    @Test("a rate-limit LLM error classifies as fatal quota")
    func rateLimitedIsFatalQuota() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .error(LLMError.rateLimited),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let outcome = await setup.dispatcher.generate(reference: reference(id: "req-quota"))
        #expect(classification(of: outcome) == .fatalQuota)
    }

    @Test("a transient request failure classifies as retryable")
    func requestFailureIsRetryable() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .error(LLMError.requestFailed("timeout")),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let outcome = await setup.dispatcher.generate(reference: reference(id: "req-transient"))
        #expect(classification(of: outcome) == .retryable)
    }

    @Test("a model that never calls the tool classifies as retryable")
    func noToolCallIsRetryable() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "Sure!"),
                .messageComplete(usage: TokenUsage(inputTokens: 4, outputTokens: 2)),
            ],
        ])
        let outcome = await setup.dispatcher.generate(reference: reference(id: "req-notool"))
        #expect(classification(of: outcome) == .retryable)
    }

    @Test("a tool call that returns an error classifies as retryable")
    func toolErrorIsRetryable() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "Sorry."),
                .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
            ],
        ])
        // Tool failures are retryable from the bulk runner perspective.
        await setup.toolExecutor.setResult(ToolResult(
            toolID: "bible.annotate",
            content: "target arguments were invalid",
            isError: true,
            artifacts: []
        ))
        let outcome = await setup.dispatcher.generate(reference: reference(id: "req-toolerr"))
        #expect(classification(of: outcome) == .retryable)
    }

    @Test("no active provider classifies as fatal auth")
    func noProviderIsFatalAuth() async throws {
        let setup = try await makeSetup(scripts: [], registerProvider: false, seedSelectedModel: false)
        let outcome = await setup.dispatcher.generate(reference: reference(id: "req-noprovider"))
        #expect(classification(of: outcome) == .fatalAuth)
    }

    @Test("a scripted tool call classifies as success with the artifact count")
    func toolCallIsSuccess() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "Done."),
                .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
            ],
        ])
        let outcome = await setup.dispatcher.generate(reference: reference(id: "req-ok"))
        #expect(outcome == .success(annotationCount: 2))
    }

    @Test("a selection desynced from the active provider resolves the active provider's model, not a failure")
    func desyncedSelectionUsesActiveProviderModel() async throws {
        // An unavailable selected provider can leave a stale model ID. Use the
        // active provider model, as normal chat sessions do.
        let setup = try await makeSetup(
            scripts: [
                [
                    .messageStart(id: "m1", model: "fake-model-1"),
                    .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:]), signature: nil),
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
        let result = await setup.dispatcher.generate(reference: request).asResult

        #expect(result == .success(annotationCount: 2))
        #expect(await setup.toolExecutor.executionCount() == 1)

        let capturedModels = await setup.provider.capturedRequests().map(\.modelID)
        #expect(!capturedModels.isEmpty)
        #expect(capturedModels.allSatisfy { $0 == "fake-model-1" })

        let lingering = try await setup.conversationRepo.fetch(id: "id-1")
        #expect(lingering == nil)
    }

    // MARK: - Per-scope section guidance

    @Test("a book request's prompt names the book-level sections to cover")
    func bookPromptNamesBookSections() {
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(kind: "book", sourceID: "book:ROM")
        )
        #expect(prompt.contains("this book"))
        #expect(prompt.contains("authorship"))
        #expect(prompt.contains("major themes"))
        #expect(prompt.contains("historical setting"))
    }

    @Test("a chapter request's prompt names the chapter-level sections to cover")
    func chapterPromptNamesChapterSections() {
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(kind: "chapter", sourceID: "chapter:ROM:8")
        )
        #expect(prompt.contains("this chapter"))
        #expect(prompt.contains("argument or narrative"))
        #expect(prompt.contains("outline of its movements"))
        #expect(prompt.contains("context"))
    }

    @Test("a verse-range request's prompt names the verse-level sections to cover")
    func versePromptNamesVerseSections() {
        // Bible references use verseRange; the tool target uses verse.
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(kind: "verseRange", sourceID: "verse:ROM:8:28:30")
        )
        #expect(prompt.contains("this verse range"))
        #expect(prompt.contains("plain language"))
        #expect(prompt.contains("historical and literary"))
        #expect(prompt.contains("cross-reference"))
    }

    @Test("a snapshot grounds the prompt in the exact verse text")
    func promptIncludesSnapshotText() {
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(snapshot: "28. And we know that all things work together for good")
        )
        #expect(prompt.contains("Exact text of the target"))
        #expect(prompt.contains("28. And we know that all things work together for good"))
        #expect(prompt.contains("Call `bible.annotate` once"))
    }

    @Test("an empty snapshot omits the grounding block")
    func promptOmitsEmptySnapshot() {
        let prompt = BibleAnnotateDispatcher.prompt(for: reference(snapshot: ""))
        #expect(!prompt.contains("Exact text of the target"))
    }

    @Test("an unrecognised kind falls back to the generic prompt with no scope line")
    func unknownKindFallsBackToGenericPrompt() {
        let prompt = BibleAnnotateDispatcher.prompt(
            for: reference(kind: "mystery", sourceID: "mystery:ROM")
        )
        #expect(!prompt.contains("structure the summary around"))
        #expect(BibleAnnotateDispatcher.sectionGuidance(forKind: "mystery") == nil)
        #expect(prompt.contains("Target kind: mystery"))
        #expect(prompt.contains("Reference id: mystery:ROM"))
        #expect(prompt.contains("Romans 8:28-30 (WEB)"))
        #expect(prompt.contains("Call `bible.annotate` once"))
    }

    @Test("the dispatcher briefing keeps its load-bearing one-tool mandate")
    func briefingKeepsToolMandate() {
        let briefing = BibleAnnotateDispatcher.dispatcherBriefing
        #expect(briefing.contains("`bible.annotate`"))
        #expect(briefing.contains("exactly once"))
        #expect(briefing.contains("do not call any other tool"))
    }

    @Test("the dispatcher briefing teaches the single-summary contract")
    func briefingCarriesSingleSummaryContract() {
        let briefing = BibleAnnotateDispatcher.dispatcherBriefing
        #expect(briefing.contains("ONE markdown study summary in `summary`"))
        #expect(briefing.contains("150–400 words"))
        #expect(briefing.contains("`###` headings"))
        #expect(!briefing.contains("category"))
    }

    @Test("the dispatcher briefing pins the full-book-name citation format")
    func briefingPinsCitationFormat() {
        // The shared renderer linkifies this exact citation format.
        let briefing = BibleAnnotateDispatcher.dispatcherBriefing
        #expect(briefing.contains("full book name"))
        #expect(briefing.contains("Book Chapter:Verse"))
    }

    @Test("the dispatcher briefing forbids repeating the verse text verbatim")
    func briefingForbidsVerbatimVerseText() {
        // The reader already displays the target verse above the summary.
        let briefing = BibleAnnotateDispatcher.dispatcherBriefing
        #expect(briefing.contains("Do NOT repeat the target's verse text verbatim"))
    }

    @Test("the dispatcher briefing restricts cross-references to genuine intertextual links")
    func briefingRestrictsCrossReferences() {
        let briefing = BibleAnnotateDispatcher.dispatcherBriefing.lowercased()
        #expect(briefing.contains("alludes to"))
        #expect(briefing.contains("thematically"))
        #expect(!briefing.contains("illuminating"))
    }

    @Test("verse-range section guidance makes the cross-references section conditional")
    func verseRangeCrossReferenceGuidanceIsConditional() {
        let guidance = BibleAnnotateDispatcher.sectionGuidance(forKind: "verseRange")?.lowercased()
        #expect(guidance?.contains("genuine cross-references") == true)
        #expect(guidance?.contains("omit the section entirely") == true)
    }

    // MARK: - Notable verses (bulk chapterVerses mode)

    @Test("a chapterVerses dispatch counts every bible.annotate call in the turn")
    func chapterVersesAccumulatesMultipleToolCalls() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-1", name: "bible.annotate", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .toolUse(index: 0, id: "tu-2", name: "bible.annotate", input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            ],
            [
                .messageStart(id: "m3", model: "fake-model-1"),
                .textDelta(index: 0, text: "Done."),
                .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 1)),
            ],
        ])
        await setup.toolExecutor.setResult(ToolResult(
            toolID: "bible.annotate",
            content: "Wrote an annotation for the target.",
            isError: false,
            artifacts: [ToolResult.Artifact(type: "annotation", id: "ann-x")]
        ))

        let outcome = await setup.dispatcher.generate(
            reference: chapterVersesReference()
        )
        #expect(outcome == .success(annotationCount: 2))
        #expect(await setup.toolExecutor.executionCount() == 2)
    }

    @Test("the chapterVerses kind selects the notable-verses briefing, others the default")
    func chapterVersesSelectsNotableVersesBriefing() {
        #expect(BibleAnnotateDispatcher.briefing(forKind: "chapterVerses")
            == BibleAnnotateDispatcher.notableVersesBriefing)
        for kind in ["book", "chapter", "verseRange", "mystery"] {
            #expect(BibleAnnotateDispatcher.briefing(forKind: kind)
                == BibleAnnotateDispatcher.dispatcherBriefing)
        }
    }

    @Test("the notable-verses briefing asks for up to five per-verse tool calls")
    func notableVersesBriefingAsksForMultipleVerseCalls() {
        let briefing = BibleAnnotateDispatcher.notableVersesBriefing
        #expect(briefing.contains("up to 5"))
        #expect(briefing.contains("once for EACH"))
        #expect(briefing.contains("\"verse\""))
        #expect(briefing.contains("at least one call"))
        #expect(!briefing.contains("exactly once"))
    }

    @Test("a chapterVerses prompt asks for one tool call per notable verse range")
    func chapterVersesPromptAsksForPerRangeCalls() {
        let prompt = BibleAnnotateDispatcher.prompt(for: chapterVersesReference())
        #expect(prompt.contains("once for each"))
        #expect(prompt.contains("most notable verse ranges"))
        #expect(!prompt.contains("Call `bible.annotate` once"))
    }

    @Test("chapterVerses section guidance steers each chosen range")
    func chapterVersesSectionGuidanceStreersEachRange() {
        let guidance = BibleAnnotateDispatcher.sectionGuidance(forKind: "chapterVerses")?.lowercased()
        #expect(guidance?.contains("each verse range you choose") == true)
        #expect(guidance?.contains("cross-references") == true)
    }

    private func chapterVersesReference(id: String = "req-cv") -> RecordReference {
        RecordReference(
            appletID: "bible",
            kind: "chapterVerses",
            sourceID: "chapterVerses:ROM:8",
            displayLabel: "Romans 8",
            citation: "Romans 8 (WEB)",
            snapshot: "1. There is therefore now no condemnation...\n28. And we know...",
            id: id
        )
    }
}
