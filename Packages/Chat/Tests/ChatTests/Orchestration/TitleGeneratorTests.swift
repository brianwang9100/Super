import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `TitleGenerator`'s model resolution, prompt assembly, stream
/// consumption, and title cleanup. The provider is the in-tree
/// `FakeLLMProvider` from `Helpers/`, so no network or real LLM is touched.
/// The summarizer model + toggle are read from an in-memory
/// `ChatSettingsStore`.
@Suite("TitleGenerator")
struct TitleGeneratorTests {
    private let model = OrchestrationFixtures.defaultModel()

    /// Build a store whose title-summarization toggle and selected model id
    /// are seeded directly. Defaults select the fixture provider by its
    /// **record id** (`"fake"`, the default `FakeLLMProvider.id`) so the title
    /// path resolves through `provider(id:)`.
    private func makeStore(enabled: Bool = true, titleModelId: String? = "fake") async -> ChatSettingsStore {
        let repo = InMemorySettingRepository()
        let store = ChatSettingsStore(repository: repo)
        try? await store.setSummarizeTitlesEnabled(enabled)
        try? await store.setTitleModelId(titleModelId)
        return store
    }

    @Test("Concatenates streamed text deltas into a single title")
    func generateAccumulatesStreamedText() async throws {
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .textDelta(index: 0, text: "Onboard"),
            .textDelta(index: 0, text: "ing "),
            .textDelta(index: 0, text: "checklist"),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 3)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(provider)

        let generator = TitleGenerator(llmProviderRegistry: registry, settingsStore: await makeStore())
        let title = await generator.generate(
            userText: "Help me onboard a new hire",
            assistantText: "Sure, here is a checklist..."
        )

        #expect(title == "Onboarding checklist")
    }

    @Test("Wrapping quotes and trailing sentence punctuation are stripped")
    func generateCleansWrappingQuotesAndPunctuation() async throws {
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .textDelta(index: 0, text: "  \"Trip plan to Lisbon!\"\n"),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 4)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(provider)

        let generator = TitleGenerator(llmProviderRegistry: registry, settingsStore: await makeStore())
        let title = await generator.generate(
            userText: "I'm planning a trip to Lisbon",
            assistantText: "Lisbon is a great choice"
        )

        #expect(title == "Trip plan to Lisbon")
    }

    @Test("Empty stream returns nil so caller can leave the placeholder")
    func generateReturnsNilOnEmptyStream() async throws {
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(provider)

        let generator = TitleGenerator(llmProviderRegistry: registry, settingsStore: await makeStore())
        let title = await generator.generate(userText: "Hi", assistantText: "Hello")

        #expect(title == nil)
    }

    @Test("Provider error returns nil rather than throwing")
    func generateReturnsNilOnProviderError() async throws {
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .error(.unauthorized),
            .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(provider)

        let generator = TitleGenerator(llmProviderRegistry: registry, settingsStore: await makeStore())
        let title = await generator.generate(userText: "Hi", assistantText: "Hello")

        #expect(title == nil)
    }

    @Test("No registered provider returns nil cleanly")
    func generateReturnsNilWhenRegistryEmpty() async throws {
        let registry = LLMProviderRegistry()
        let generator = TitleGenerator(llmProviderRegistry: registry, settingsStore: await makeStore())
        let title = await generator.generate(userText: "Hi", assistantText: "Hello")
        #expect(title == nil)
    }

    @Test("Disabled toggle returns nil and never calls the provider")
    func generateSkipsWhenSummarizationDisabled() async throws {
        let provider = FakeLLMProvider(model: model)
        // No script enqueued: a stream call would `fatalError`, proving the
        // provider must not be touched when titling is off.
        let registry = LLMProviderRegistry()
        await registry.register(provider)

        let generator = TitleGenerator(
            llmProviderRegistry: registry,
            settingsStore: await makeStore(enabled: false)
        )
        let title = await generator.generate(userText: "Hi", assistantText: "Hello")

        #expect(title == nil)
        #expect(await provider.capturedRequests().isEmpty)
    }

    @Test("Automatic titles do not inherit a PCC-only fresh setup")
    func automaticTitlesDoNotUsePCCDefault() async {
        let pccModel = LLMModel(
            id: AppleFoundationModel.privateCloudCompute.rawValue,
            displayName: "Apple Intelligence — Private Cloud Compute",
            supportsThinking: false, supportsTools: true, maxContextTokens: 32_768
        )
        // No script: any implicit cloud request would fail the strict fake.
        let pcc = FakeLLMProvider(id: "pcc", model: pccModel)
        let registry = LLMProviderRegistry()
        await registry.register(pcc)
        let generator = TitleGenerator(
            llmProviderRegistry: registry, settingsStore: await makeStore(titleModelId: nil)
        )
        #expect(await generator.generate(userText: "Study", assistantText: "Response") == nil)
        #expect(await pcc.capturedRequests().isEmpty)
    }

    @Test("Explicit PCC title selection is honored")
    func explicitPCCTitles() async {
        let pccModel = LLMModel(
            id: AppleFoundationModel.privateCloudCompute.rawValue,
            displayName: "Apple Intelligence — Private Cloud Compute",
            supportsThinking: false, supportsTools: true, maxContextTokens: 32_768
        )
        let pcc = FakeLLMProvider(id: "pcc", model: pccModel)
        await pcc.enqueue([
            .messageStart(id: "title", model: pccModel.id),
            .textDelta(index: 0, text: "Study notes"),
            .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 2)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(pcc)
        let generator = TitleGenerator(
            llmProviderRegistry: registry, settingsStore: await makeStore(titleModelId: "pcc")
        )
        #expect(await generator.generate(userText: "Study", assistantText: "Response") == "Study notes")
        #expect(await pcc.capturedRequests().count == 1)
    }

    @Test("Automatic selection titles with the Apple Foundation model when available")
    func generateAutomaticUsesAppleFoundationModel() async throws {
        let afmModel = LLMModel(
            id: AppleFoundationLLMProvider.defaultModelID,
            displayName: "Apple Intelligence",
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: 8_192
        )
        let provider = FakeLLMProvider(id: "afm", model: afmModel)
        await provider.enqueue([
            .messageStart(id: "t1", model: afmModel.id),
            .textDelta(index: 0, text: "On-device title"),
            .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 2)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(provider)

        // titleModelId: nil ⇒ automatic ⇒ AFM.
        let generator = TitleGenerator(
            llmProviderRegistry: registry,
            settingsStore: await makeStore(titleModelId: nil)
        )
        let title = await generator.generate(userText: "Hi", assistantText: "Hello")

        #expect(title == "On-device title")
    }

    @Test("A deleted (unavailable) selected model resolves to no titling")
    func generateReturnsNilWhenSelectedModelUnavailable() async throws {
        let provider = FakeLLMProvider(model: model)
        let registry = LLMProviderRegistry()
        await registry.register(provider)

        // Selected id points at a model no registered provider serves.
        let generator = TitleGenerator(
            llmProviderRegistry: registry,
            settingsStore: await makeStore(titleModelId: "deleted-model-id")
        )
        let title = await generator.generate(userText: "Hi", assistantText: "Hello")

        #expect(title == nil)
        #expect(await provider.capturedRequests().isEmpty)
    }

    @Test("Two providers sharing a modelId: titling routes to the selected record, not the first")
    func generateRoutesBySharedModelIdRecord() async throws {
        // End-to-end convergence regression. Both providers vend the same
        // `model.id` ("debug-default") but have distinct record ids — the debug
        // canned / mock-search shape. `titleModelId` names the mock-search
        // record, so only that provider must stream. The old `forModelId` scan
        // resolved to the first by sorted id ("debug-canned"), titling from the
        // wrong provider.
        let shared = LLMModel(
            id: "debug-default", displayName: "Debug",
            supportsThinking: false, supportsTools: false, maxContextTokens: 8_192
        )
        let canned = FakeLLMProvider(id: "debug-canned", model: shared)
        let mock = FakeLLMProvider(id: "debug-mock-search", model: shared)
        await canned.enqueue([
            .messageStart(id: "c1", model: shared.id),
            .textDelta(index: 0, text: "CANNED"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ])
        await mock.enqueue([
            .messageStart(id: "m1", model: shared.id),
            .textDelta(index: 0, text: "Mock title"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(canned)
        await registry.register(mock)

        let generator = TitleGenerator(
            llmProviderRegistry: registry,
            settingsStore: await makeStore(titleModelId: "debug-mock-search")
        )
        let title = await generator.generate(userText: "Hi", assistantText: "Hello")

        #expect(title == "Mock title")
        // The canned provider must never have been asked to stream.
        #expect(await canned.capturedRequests().isEmpty)
    }

    @Test("Sends a system+user message pair to the provider")
    func generateSendsSystemAndUserMessages() async throws {
        let provider = FakeLLMProvider(model: model)
        await provider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .textDelta(index: 0, text: "Title"),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 1)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(provider)

        let generator = TitleGenerator(llmProviderRegistry: registry, settingsStore: await makeStore())
        _ = await generator.generate(
            userText: "first user line",
            assistantText: "first assistant line"
        )

        let captured = await provider.capturedRequests()
        #expect(captured.count == 1)
        #expect(captured.first?.messages.map(\.role) == [.system, .user])
        // Tools must be empty so a tools-capable model doesn't try to
        // invoke a tool when generating a title.
        #expect(captured.first?.tools.isEmpty == true)

        if case .text(let userText) = captured.first?.messages.last?.content.first {
            #expect(userText.contains("first user line"))
            #expect(userText.contains("first assistant line"))
            // `/no_think` skips Qwen3's reasoning chain on the title
            // call. Pinned to the trailing position because the chat
            // template scans for it as the last token of the user
            // message.
            #expect(userText.hasSuffix("/no_think"))
        } else {
            Issue.record("expected user message to be a text block, got \(String(describing: captured.first?.messages.last?.content))")
        }
    }

    // MARK: - resolveTitleModel

    private func selectable(recordId: String, modelId: String) -> SelectableModel {
        SelectableModel(
            recordId: recordId,
            model: LLMModel(id: modelId, displayName: modelId, supportsThinking: false, supportsTools: true, maxContextTokens: 1)
        )
    }

    @Test("Explicit selection resolves to the matching record id")
    func resolveExplicitSelection() {
        let a = selectable(recordId: "rec-a", modelId: "a")
        let b = selectable(recordId: "rec-b", modelId: "b")
        #expect(TitleGenerator.resolveTitleModel(selectedRecordId: "rec-b", available: [a, b])?.recordId == "rec-b")
    }

    @Test("Two rows sharing a modelId resolve to the picked record id, not the first")
    func resolveDistinguishesSharedModelId() {
        // The convergence guarantee for the title path: two providers vending
        // the same `model.id` (the debug canned/mock-search case) must resolve
        // by record id. The old `forModelId` scan returned the first by sorted
        // id ("debug-canned"); keying on record id returns exactly the pick.
        let canned = selectable(recordId: "debug-canned", modelId: "debug-default")
        let mock = selectable(recordId: "debug-mock-search", modelId: "debug-default")
        let resolved = TitleGenerator.resolveTitleModel(
            selectedRecordId: "debug-mock-search", available: [canned, mock]
        )
        #expect(resolved?.recordId == "debug-mock-search")
    }

    @Test("A legacy persisted model id still resolves (back-compat)")
    func resolveLegacyModelId() {
        let a = selectable(recordId: "rec-a", modelId: "a")
        let b = selectable(recordId: "rec-b", modelId: "b")
        // "b" is a model id, not a record id — the back-compat branch maps it.
        #expect(TitleGenerator.resolveTitleModel(selectedRecordId: "b", available: [a, b])?.recordId == "rec-b")
    }

    @Test("A selected id absent from the available list resolves to nil (deleted → none)")
    func resolveDeletedSelection() {
        let a = selectable(recordId: "rec-a", modelId: "a")
        #expect(TitleGenerator.resolveTitleModel(selectedRecordId: "gone", available: [a]) == nil)
    }

    @Test("Automatic resolves to the Apple Foundation model when present, else nil")
    func resolveAutomatic() {
        let afm = selectable(recordId: "afm", modelId: AppleFoundationLLMProvider.defaultModelID)
        let other = selectable(recordId: "other", modelId: "other")
        #expect(TitleGenerator.resolveTitleModel(selectedRecordId: nil, available: [other, afm])?.recordId == "afm")
        // AFM not in the available list (unsupported device) ⇒ none.
        #expect(TitleGenerator.resolveTitleModel(selectedRecordId: nil, available: [other]) == nil)
    }

    // MARK: - clean

    @Test("Cleans whitespace-only output to nil")
    func cleanReturnsNilForWhitespaceOnly() {
        #expect(TitleGenerator.clean("   \n\t", maxLength: 60) == nil)
    }

    @Test("Caps cleaned title at maxLength")
    func cleanCapsAtMaxLength() {
        let raw = String(repeating: "abc ", count: 50)
        let cleaned = TitleGenerator.clean(raw, maxLength: 20)
        #expect((cleaned?.count ?? 0) <= 20)
        #expect(cleaned?.hasPrefix("abc") == true)
    }

    @Test("Strips smart quotes and backticks")
    func cleanStripsSmartQuotesAndBackticks() {
        #expect(TitleGenerator.clean("“Hello world”", maxLength: 60) == "Hello world")
        #expect(TitleGenerator.clean("`code review notes`", maxLength: 60) == "code review notes")
    }
}

/// In-memory `SettingRepository` for the title-summarizer tests.
private actor InMemorySettingRepository: SettingRepository {
    private var storage: [String: String] = [:]

    func get(_ key: String) async throws -> String? { storage[key] }
    func set(_ key: String, value: String) async throws { storage[key] = value }
    func delete(_ key: String) async throws { storage.removeValue(forKey: key) }
    func all() async throws -> [String: String] { storage }
}
