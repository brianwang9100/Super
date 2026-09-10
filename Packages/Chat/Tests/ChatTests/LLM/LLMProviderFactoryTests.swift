import Core
import Foundation
import Testing
@testable import Chat

@Suite("makeLLMProvider")
struct LLMProviderFactoryTests {
    private let http = FakeHTTPClient(chunks: [])
    private let toolRegistry = ToolRegistry()
    // Fix availability to avoid depending on the test host.
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

    private func make(_ record: ModelConfigurationRecord) -> (any LLMProvider)? {
        makeLLMProvider(
            for: record,
            apiKey: "sk-test",
            http: http,
            toolRegistry: toolRegistry,
            appleFoundationAvailability: afmUnavailable
        )
    }

    @Test("builds an OpenAIResponsesLLMProvider for an .openAIResponses row")
    func buildsResponsesProvider() {
        let provider = make(record(kind: .openAIResponses))
        #expect(provider is OpenAIResponsesLLMProvider)
        #expect(provider?.id == "row-openAIResponses")
    }

    @Test("builds an OpenAICompatibleLLMProvider for an .openAICompatible row")
    func buildsCompatProvider() {
        let provider = make(record(kind: .openAICompatible))
        #expect(provider is OpenAICompatibleLLMProvider)
    }

    @Test("builds an AnthropicNativeLLMProvider for an .anthropicNative row")
    func buildsAnthropicProvider() {
        let provider = make(record(kind: .anthropicNative))
        #expect(provider is AnthropicNativeLLMProvider)
        #expect(provider?.id == "row-anthropicNative")
    }

    @Test("builds a GeminiNativeLLMProvider for a .geminiNative row")
    func buildsGeminiProvider() {
        let provider = make(record(kind: .geminiNative))
        #expect(provider is GeminiNativeLLMProvider)
        #expect(provider?.id == "row-geminiNative")
    }

    @Test("returns nil (no crash) for a network kind whose row is missing baseURL")
    func returnsNilForNilBaseURL() {
        // Synced or corrupt rows may lack a URL; skip them before the initializer
        // precondition can crash every launch.
        #expect(make(record(kind: .openAIResponses, baseURL: nil)) == nil)
        #expect(make(record(kind: .openAICompatible, baseURL: nil)) == nil)
        #expect(make(record(kind: .anthropicNative, baseURL: nil)) == nil)
        #expect(make(record(kind: .geminiNative, baseURL: nil)) == nil)
    }

    @Test("returns nil for HTTP-backed kinds when no client is supplied")
    func returnsNilWithoutHTTPClient() {
        let provider = makeLLMProvider(
            for: record(kind: .openAIResponses),
            apiKey: "sk-test",
            http: nil,
            toolRegistry: toolRegistry,
            appleFoundationAvailability: afmUnavailable
        )
        #expect(provider == nil)
    }

    #if DEBUG
    @Test("dispatches the .debug arm on modelId across the three debug providers")
    func buildsDebugProvidersByModelId() {
        func debugRow(modelId: String) -> ModelConfigurationRecord {
            ModelConfigurationRecord(
                id: "row-\(modelId)", name: modelId, baseURL: nil, apiKeyRef: nil,
                modelId: modelId, createdAt: Date(timeIntervalSince1970: 0), kind: .debug
            )
        }
        #expect(make(debugRow(modelId: DebugAnnotateLLMProvider.modelID)) is DebugAnnotateLLMProvider)
        #expect(make(debugRow(modelId: DebugNoteLLMProvider.modelID)) is DebugNoteLLMProvider)
        #expect(make(debugRow(modelId: DebugHighlightLLMProvider.modelID)) is DebugHighlightLLMProvider)
        #expect(make(debugRow(modelId: DebugLLMProvider.modelID)) is DebugLLMProvider)
        #expect(make(debugRow(modelId: "anything-else")) is DebugLLMProvider)
    }

    /// Rows sharing modelId need distinct picker identities and labels.
    @Test("two debug rows sharing modelId vend distinct picker entries")
    func debugRowsVendDistinctModels() {
        func cannedRow(id: String, name: String, searchBackend: String? = nil) -> ModelConfigurationRecord {
            ModelConfigurationRecord(
                id: id, name: name, baseURL: nil, apiKeyRef: nil,
                modelId: DebugLLMProvider.modelID,
                createdAt: Date(timeIntervalSince1970: 0), kind: .debug,
                searchBackend: searchBackend
            )
        }
        let canned = make(cannedRow(id: "debug-canned", name: "Debug (canned)"))
        let mock = make(cannedRow(id: "debug-mock-search", name: "Debug (mock search)", searchBackend: "debug"))

        let cannedModel = canned?.supportedModels.first
        let mockModel = mock?.supportedModels.first
        #expect(cannedModel?.id == "debug-canned")
        #expect(mockModel?.id == "debug-mock-search")
        #expect(cannedModel?.displayName == "Debug (canned)")
        #expect(mockModel?.displayName == "Debug (mock search)")
    }
    #endif
}
