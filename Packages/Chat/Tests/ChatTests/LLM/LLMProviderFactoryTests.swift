import Core
import Foundation
import Testing
@testable import Chat

/// Coverage for `makeLLMProvider` — the single per-kind provider factory
/// shared by the launch path (`AppBootstrapSupport.hydrateProviders`) and the
/// Settings path (`SettingsViewModel.registerProvider`). The two used to
/// duplicate the switch; this pins the contract so they can't drift.
@Suite("makeLLMProvider")
struct LLMProviderFactoryTests {
    private let http = FakeHTTPClient(chunks: [])
    private let toolRegistry = ToolRegistry()
    // Fixed unavailable AFM so the test doesn't pick up host state; none of
    // these cases reach the `.appleFoundation` arm anyway.
    private let afmUnavailable: AppleFoundationAvailability = .unavailable(.deviceNotEligible)

    private func record(kind: LLMProviderKind, baseURL: URL? = URL(string: "https://api.openai.com/v1")) -> ModelConfigurationRecord {
        ModelConfigurationRecord(
            id: "row-\(kind.rawValue)",
            name: "Test \(kind.rawValue)",
            baseURL: baseURL,
            apiKeyRef: nil,
            modelId: "gpt-5.1",
            createdAt: Date(timeIntervalSince1970: 0),
            kind: kind,
            supportsThinking: false,
            maxContextTokens: 200_000,
            isSelected: false,
            searchBackend: [.openAIResponses, .anthropicNative, .geminiNative].contains(kind) ? "native" : nil
        )
    }

    private func make(_ record: ModelConfigurationRecord) async -> (any LLMProvider)? {
        await makeLLMProvider(
            for: record,
            apiKey: "sk-test",
            http: http,
            toolRegistry: toolRegistry,
            appleFoundationAvailability: afmUnavailable
        )
    }

    @Test("builds an OpenAIResponsesLLMProvider for an .openAIResponses row")
    func buildsResponsesProvider() async {
        let provider = await make(record(kind: .openAIResponses))
        #expect(provider is OpenAIResponsesLLMProvider)
        #expect(provider?.id == "row-openAIResponses")
    }

    @Test("builds an OpenAICompatibleLLMProvider for an .openAICompatible row")
    func buildsCompatProvider() async {
        let provider = await make(record(kind: .openAICompatible))
        #expect(provider is OpenAICompatibleLLMProvider)
    }

    @Test("builds an AnthropicNativeLLMProvider for an .anthropicNative row")
    func buildsAnthropicProvider() async {
        let provider = await make(record(kind: .anthropicNative))
        #expect(provider is AnthropicNativeLLMProvider)
        #expect(provider?.id == "row-anthropicNative")
    }

    @Test("builds a GeminiNativeLLMProvider for a .geminiNative row")
    func buildsGeminiProvider() async {
        let provider = await make(record(kind: .geminiNative))
        #expect(provider is GeminiNativeLLMProvider)
        #expect(provider?.id == "row-geminiNative")
    }

    @Test("returns nil (no crash) for a network kind whose row is missing baseURL")
    func returnsNilForNilBaseURL() async {
        // A nullable column: a corrupt/synced row could carry a network kind
        // with nil baseURL. The factory must skip it, not hit the init's
        // preconditionFailure (which would crash on every launch).
        #expect(await make(record(kind: .openAIResponses, baseURL: nil)) == nil)
        #expect(await make(record(kind: .openAICompatible, baseURL: nil)) == nil)
        #expect(await make(record(kind: .anthropicNative, baseURL: nil)) == nil)
        #expect(await make(record(kind: .geminiNative, baseURL: nil)) == nil)
    }

    @Test("returns nil for HTTP-backed kinds when no client is supplied")
    func returnsNilWithoutHTTPClient() async {
        let provider = await makeLLMProvider(
            for: record(kind: .openAIResponses),
            apiKey: "sk-test",
            http: nil,
            toolRegistry: toolRegistry,
            appleFoundationAvailability: afmUnavailable
        )
        #expect(provider == nil)
    }

    private func appleRecord(modelId: String) -> ModelConfigurationRecord {
        ModelConfigurationRecord(
            id: "apple-\(modelId)", name: "Custom Apple name", baseURL: nil, apiKeyRef: nil,
            modelId: modelId, createdAt: Date(timeIntervalSince1970: 0),
            kind: .appleFoundation, isSelected: true
        )
    }

    @Test("local Apple routing preserves the existing persisted model identifier")
    func buildsLocalAppleProviderWithoutHTTPClient() async throws {
        let record = appleRecord(modelId: AppleFoundationLLMProvider.defaultModelID)
        let built = await makeLLMProvider(
            for: record, apiKey: nil, http: nil, toolRegistry: toolRegistry,
            appleFoundationStatusProvider: FixedAppleFoundationModelStatusProvider(
                localAvailability: .available, localContextTokens: 8_192
            )
        )
        let provider = try #require(built)
        #expect(provider is AppleFoundationLLMProvider)
        #expect(provider.id == record.id)
        #expect(provider.supportedModels.count == 1)
        #expect(provider.supportedModels.first?.id == "system-default")
        #expect(provider.supportedModels.first?.maxContextTokens == 8_192)
    }

    @Test("model-specific status takes precedence over the legacy local availability input")
    func explicitStatusProviderWinsOverLegacyAvailability() async throws {
        let built = await makeLLMProvider(
            for: appleRecord(modelId: AppleFoundationModel.local.rawValue),
            apiKey: nil, http: nil, toolRegistry: toolRegistry,
            appleFoundationAvailability: afmUnavailable,
            appleFoundationStatusProvider: FixedAppleFoundationModelStatusProvider(
                localAvailability: .available, localContextTokens: 12_000
            )
        )
        let provider = try #require(built)
        #expect(provider.supportedModels.first?.maxContextTokens == 12_000)
    }

    @Test("unavailable local Apple models keep a selectable provider identity")
    func unavailableLocalModelDoesNotFallThrough() async throws {
        let record = appleRecord(modelId: AppleFoundationModel.local.rawValue)
        let provider = try #require(await make(record))
        let model = try #require(provider.supportedModels.first)
        #expect(provider.id == record.id)
        #expect(model.id == AppleFoundationModel.local.rawValue)

        var events: [LLMStreamEvent] = []
        for try await event in provider.stream(
            messages: [LLMMessage(role: .user, text: "Synthetic unavailable-model test")],
            model: model, tools: [], temperature: 0
        ) {
            events.append(event)
        }
        let reason = AppleFoundationAvailability.Reason.deviceNotEligible
        #expect(events.contains(.error(.providerError(code: reason.errorCode, message: reason.errorMessage))))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test("PCC on an unsupported OS remains PCC and explains why it cannot generate")
    func unsupportedCloudModelDoesNotBecomeLocal() async throws {
        let record = appleRecord(modelId: AppleFoundationModel.privateCloudCompute.rawValue)
        let built = await makeLLMProvider(
            for: record, apiKey: nil, http: nil, toolRegistry: toolRegistry,
            appleFoundationStatusProvider: FixedAppleFoundationModelStatusProvider(
                localAvailability: .available, supportsPrivateCloudCompute: false
            )
        )
        let provider = try #require(built)
        let model = try #require(provider.supportedModels.first)
        #expect(provider.id == record.id)
        #expect(model.id == AppleFoundationModel.privateCloudCompute.rawValue)
        #expect(model.displayName == AppleFoundationModel.privateCloudCompute.displayName)
        #expect(!model.supportsThinking)

        var events: [LLMStreamEvent] = []
        for try await event in provider.stream(
            messages: [LLMMessage(role: .user, text: "Synthetic unsupported-OS test")],
            model: model, tools: [], temperature: 0
        ) {
            events.append(event)
        }
        let reason = AppleFoundationModelStatus.Reason.requiresNewerOS
        #expect(events.contains(.error(.providerError(code: reason.errorCode, message: reason.errorMessage))))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test("unknown Apple model identifiers are rejected instead of silently using local")
    func unknownAppleModelReturnsNil() async {
        #expect(await make(appleRecord(modelId: "unknown-future-apple-model")) == nil)
    }

    @Test("local and cloud Apple rows coexist with independent provider identities")
    func appleVariantsBuildDistinctProviders() async throws {
        let local = try #require(await make(appleRecord(modelId: AppleFoundationModel.local.rawValue)))
        let cloud = try #require(await make(appleRecord(modelId: AppleFoundationModel.privateCloudCompute.rawValue)))
        #expect(local.id != cloud.id)
        #expect(local.supportedModels.first?.id == AppleFoundationModel.local.rawValue)
        #expect(cloud.supportedModels.first?.id == AppleFoundationModel.privateCloudCompute.rawValue)
    }

    @Test("an unavailable selected Apple row replaces the registry's first-provider fallback",
          arguments: AppleFoundationModel.allCases)
    func unavailableAppleSelectionRemainsActive(model: AppleFoundationModel) async throws {
        let registry = LLMProviderRegistry()
        let first = try #require(await make(record(kind: .openAICompatible)))
        let selectedRow = appleRecord(modelId: model.rawValue)
        let selected = try #require(await make(selectedRow))
        await registry.register(first)
        await registry.register(selected)
        try await registry.setActive(id: selectedRow.id)

        #expect(await registry.activeID() == selectedRow.id)
        #expect(await registry.active()?.supportedModels.first?.id == model.rawValue)
    }

    #if DEBUG
    @Test("dispatches the .debug arm on modelId across the three debug providers")
    func buildsDebugProvidersByModelId() async {
        func debugRow(modelId: String) -> ModelConfigurationRecord {
            ModelConfigurationRecord(
                id: "row-\(modelId)", name: modelId, baseURL: nil, apiKeyRef: nil,
                modelId: modelId, createdAt: Date(timeIntervalSince1970: 0), kind: .debug
            )
        }
        #expect(await make(debugRow(modelId: DebugAnnotateLLMProvider.modelID)) is DebugAnnotateLLMProvider)
        #expect(await make(debugRow(modelId: DebugNoteLLMProvider.modelID)) is DebugNoteLLMProvider)
        #expect(await make(debugRow(modelId: DebugHighlightLLMProvider.modelID)) is DebugHighlightLLMProvider)
        // Any other (or the canned) modelId falls through to the stream provider.
        #expect(await make(debugRow(modelId: DebugLLMProvider.modelID)) is DebugLLMProvider)
        #expect(await make(debugRow(modelId: "anything-else")) is DebugLLMProvider)
    }

    /// Regression: the two `DebugLLMProvider`-backed rows ("Debug (canned)" and
    /// "Debug (mock search)") share `modelId`, so they used to vend an
    /// identical static model id + label — the picker showed two "Debug
    /// stream" entries and the old model-id provider scan always resolved to the
    /// first, leaving the mock-search row unselectable. The vended model now
    /// carries the per-row provider id and the row's `name`.
    @Test("two debug rows sharing modelId vend distinct picker entries")
    func debugRowsVendDistinctModels() async {
        func cannedRow(id: String, name: String, searchBackend: String? = nil) -> ModelConfigurationRecord {
            ModelConfigurationRecord(
                id: id, name: name, baseURL: nil, apiKeyRef: nil,
                modelId: DebugLLMProvider.modelID,
                createdAt: Date(timeIntervalSince1970: 0), kind: .debug,
                searchBackend: searchBackend
            )
        }
        let canned = await make(cannedRow(id: "debug-canned", name: "Debug (canned)"))
        let mock = await make(cannedRow(id: "debug-mock-search", name: "Debug (mock search)", searchBackend: "debug"))

        let cannedModel = canned?.supportedModels.first
        let mockModel = mock?.supportedModels.first
        // Distinct ids so any context that still surfaces the vended model id
        // can tell the two rows apart (selection itself keys on the record id).
        #expect(cannedModel?.id == "debug-canned")
        #expect(mockModel?.id == "debug-mock-search")
        // Labels mirror the seeded row names rather than one shared static.
        #expect(cannedModel?.displayName == "Debug (canned)")
        #expect(mockModel?.displayName == "Debug (mock search)")
    }
    #endif
}
