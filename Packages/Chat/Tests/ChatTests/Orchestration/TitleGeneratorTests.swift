import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `TitleGenerator`'s prompt assembly, stream consumption, and
/// title cleanup. The provider is the in-tree `FakeLLMProvider` from
/// `Helpers/`, so no network or real LLM is touched.
@Suite("TitleGenerator")
struct TitleGeneratorTests {
    private let model = OrchestrationFixtures.defaultModel()

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

        let generator = TitleGenerator(llmProviderRegistry: registry)
        let title = await generator.generate(
            userText: "Help me onboard a new hire",
            assistantText: "Sure, here is a checklist...",
            model: model
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

        let generator = TitleGenerator(llmProviderRegistry: registry)
        let title = await generator.generate(
            userText: "I'm planning a trip to Lisbon",
            assistantText: "Lisbon is a great choice",
            model: model
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

        let generator = TitleGenerator(llmProviderRegistry: registry)
        let title = await generator.generate(
            userText: "Hi",
            assistantText: "Hello",
            model: model
        )

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

        let generator = TitleGenerator(llmProviderRegistry: registry)
        let title = await generator.generate(
            userText: "Hi",
            assistantText: "Hello",
            model: model
        )

        #expect(title == nil)
    }

    @Test("No active provider returns nil cleanly")
    func generateReturnsNilWhenRegistryEmpty() async throws {
        let registry = LLMProviderRegistry()
        let generator = TitleGenerator(llmProviderRegistry: registry)
        let title = await generator.generate(
            userText: "Hi",
            assistantText: "Hello",
            model: model
        )
        #expect(title == nil)
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

        let generator = TitleGenerator(llmProviderRegistry: registry)
        _ = await generator.generate(
            userText: "first user line",
            assistantText: "first assistant line",
            model: model
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
