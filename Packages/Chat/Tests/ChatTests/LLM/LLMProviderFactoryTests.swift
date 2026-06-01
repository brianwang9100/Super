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
            searchBackend: kind == .openAIResponses ? "native" : nil
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

    @Test("returns nil for native kinds whose adapter has not shipped")
    func returnsNilForUnbuiltNativeKinds() {
        #expect(make(record(kind: .geminiNative)) == nil)
    }

    @Test("returns nil (no crash) for a network kind whose row is missing baseURL")
    func returnsNilForNilBaseURL() {
        // A nullable column: a corrupt/synced row could carry a network kind
        // with nil baseURL. The factory must skip it, not hit the init's
        // preconditionFailure (which would crash on every launch).
        #expect(make(record(kind: .openAIResponses, baseURL: nil)) == nil)
        #expect(make(record(kind: .openAICompatible, baseURL: nil)) == nil)
        #expect(make(record(kind: .anthropicNative, baseURL: nil)) == nil)
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
}
