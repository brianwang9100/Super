import Core
import Foundation
import Testing
@testable import Bible

@Suite("ActiveModelBibleAnnotationStampProvider")
struct ActiveModelBibleAnnotationStampProviderTests {
    @Test("stamps the active provider's first model id")
    func stampsActiveModelID() async throws {
        let registry = LLMProviderRegistry()
        await registry.register(StubLLMProvider(
            id: "gemini",
            models: [LLMModel(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash")]
        ))
        try await registry.setActive(id: "gemini")
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

    @Test("falls back to an empty model id when the active provider advertises no models")
    func emptyWhenActiveProviderHasNoModels() async throws {
        let registry = LLMProviderRegistry()
        await registry.register(StubLLMProvider(id: "empty", models: []))
        // Select an empty model list explicitly to distinguish it from no active provider.
        try await registry.setActive(id: "empty")
        let provider = ActiveModelBibleAnnotationStampProvider(registry: registry)

        let stamp = await provider.stamp()

        #expect(stamp.modelId.isEmpty)
        #expect(stamp.source == .user)
    }

    @Test("forwards the configured source")
    func forwardsSource() async throws {
        let registry = LLMProviderRegistry()
        await registry.register(StubLLMProvider(
            id: "openai",
            models: [LLMModel(id: "gpt-4o-mini", displayName: "GPT-4o mini")]
        ))
        try await registry.setActive(id: "openai")
        let provider = ActiveModelBibleAnnotationStampProvider(
            registry: registry,
            source: .userBulk
        )

        let stamp = await provider.stamp()

        #expect(stamp.source == .userBulk)
        #expect(stamp.modelId == "gpt-4o-mini")
    }
}

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
