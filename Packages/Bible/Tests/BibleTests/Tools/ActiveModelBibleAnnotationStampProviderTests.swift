import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `ActiveModelBibleAnnotationStampProvider` — that it stamps the
/// active provider's model id, falls back to an empty id when no provider
/// is active, and forwards its configured `source`.
@Suite("ActiveModelBibleAnnotationStampProvider")
struct ActiveModelBibleAnnotationStampProviderTests {
    @Test("stamps the active provider's first model id")
    func stampsActiveModelID() async {
        let registry = LLMProviderRegistry()
        await registry.register(StubLLMProvider(
            id: "gemini",
            models: [LLMModel(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash")]
        ))
        let provider = ActiveModelBibleAnnotationStampProvider(registry: registry)

        let stamp = await provider.stamp()

        #expect(stamp.modelId == "gemini-3.5-flash")
        #expect(stamp.source == .user)
    }

    @Test("falls back to an empty model id when no provider is active")
    func emptyWhenNoActiveProvider() async {
        let registry = LLMProviderRegistry()
        let provider = ActiveModelBibleAnnotationStampProvider(registry: registry)

        let stamp = await provider.stamp()

        #expect(stamp.modelId.isEmpty)
        #expect(stamp.source == .user)
    }

    @Test("forwards the configured source")
    func forwardsSource() async {
        let registry = LLMProviderRegistry()
        await registry.register(StubLLMProvider(
            id: "openai",
            models: [LLMModel(id: "gpt-4o-mini", displayName: "GPT-4o mini")]
        ))
        let provider = ActiveModelBibleAnnotationStampProvider(
            registry: registry,
            source: .userBulk
        )

        let stamp = await provider.stamp()

        #expect(stamp.source == .userBulk)
        #expect(stamp.modelId == "gpt-4o-mini")
    }
}

/// Minimal `LLMProvider` stub — exposes a fixed model list so the stamp
/// provider can resolve an id. `stream` is never exercised by these tests.
private struct StubLLMProvider: LLMProvider {
    let id: String
    let supportedModels: [LLMModel]
    var displayName: String { id }

    init(id: String, models: [LLMModel]) {
        self.id = id
        self.supportedModels = models
    }

    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        fatalError("StubLLMProvider.stream should not be called in these tests.")
    }
}
