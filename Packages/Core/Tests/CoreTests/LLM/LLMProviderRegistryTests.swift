import Testing
@testable import Core

/// Tests for `LLMProviderRegistry` register / unregister / setActive
/// semantics, including the auto-active-on-first-register behavior.
@Suite("LLMProviderRegistry")
struct LLMProviderRegistryTests {
    @Test func startsEmpty() async {
        let registry = LLMProviderRegistry()
        #expect(await registry.active() == nil)
        #expect(await registry.allProviders().isEmpty)
    }

    @Test func firstRegisteredProviderBecomesActive() async {
        let registry = LLMProviderRegistry()
        let provider = MockLLMProvider(id: "openai")
        await registry.register(provider)
        let active = await registry.active()
        #expect(active?.id == "openai")
        #expect(await registry.activeID() == "openai")
    }

    @Test func subsequentRegistrationsDoNotOverwriteActive() async {
        let registry = LLMProviderRegistry()
        await registry.register(MockLLMProvider(id: "openai"))
        await registry.register(MockLLMProvider(id: "anthropic"))
        #expect(await registry.activeID() == "openai")
    }

    @Test func setActiveSwapsActive() async throws {
        let registry = LLMProviderRegistry()
        await registry.register(MockLLMProvider(id: "openai"))
        await registry.register(MockLLMProvider(id: "anthropic"))
        try await registry.setActive(id: "anthropic")
        #expect(await registry.activeID() == "anthropic")
    }

    @Test func setActiveThrowsForUnknown() async {
        let registry = LLMProviderRegistry()
        await registry.register(MockLLMProvider(id: "openai"))
        await #expect(throws: LLMProviderRegistryError.unknownProvider("missing")) {
            try await registry.setActive(id: "missing")
        }
    }

    @Test func requireActiveThrowsWhenEmpty() async {
        let registry = LLMProviderRegistry()
        await #expect(throws: LLMProviderRegistryError.noActiveProvider) {
            _ = try await registry.requireActive()
        }
    }

    @Test func unregisterClearsActiveAndPicksReplacement() async {
        let registry = LLMProviderRegistry()
        await registry.register(MockLLMProvider(id: "openai"))
        await registry.register(MockLLMProvider(id: "anthropic"))
        await registry.unregister(id: "openai")
        #expect(await registry.activeID() == "anthropic")
    }

    @Test func unregisterLeavesNoneWhenLastRemoved() async {
        let registry = LLMProviderRegistry()
        await registry.register(MockLLMProvider(id: "openai"))
        await registry.unregister(id: "openai")
        #expect(await registry.active() == nil)
    }

    @Test func providerLookupByID() async {
        let registry = LLMProviderRegistry()
        await registry.register(MockLLMProvider(id: "x"))
        #expect(await registry.provider(id: "x")?.id == "x")
        #expect(await registry.provider(id: "y") == nil)
    }

    @Test func providerLookupByModelID() async {
        func model(_ id: String) -> LLMModel {
            LLMModel(id: id, displayName: id, supportsThinking: false, supportsTools: true, maxContextTokens: 1)
        }
        let registry = LLMProviderRegistry()
        await registry.register(MockLLMProvider(id: "p1", supportedModels: [model("gpt-4o"), model("gpt-4o-mini")]))
        await registry.register(MockLLMProvider(id: "p2", supportedModels: [model("system-default")]))

        #expect(await registry.provider(forModelId: "gpt-4o-mini")?.id == "p1")
        #expect(await registry.provider(forModelId: "system-default")?.id == "p2")
        #expect(await registry.provider(forModelId: "missing") == nil)
    }

    @Test func allProvidersReturnsSortedByID() async {
        let registry = LLMProviderRegistry()
        await registry.register(MockLLMProvider(id: "z"))
        await registry.register(MockLLMProvider(id: "a"))
        await registry.register(MockLLMProvider(id: "m"))
        let ids = await registry.allProviders().map(\.id)
        #expect(ids == ["a", "m", "z"])
    }
}
