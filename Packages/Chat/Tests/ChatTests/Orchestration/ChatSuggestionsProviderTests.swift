import Core
import Foundation
import Testing
@testable import Chat

/// Tests for the AFM-first suggestion generator and its static fallback. Drives
/// generation through the strict `FakeLLMProvider` so no on-device model is
/// touched; covers parse/clean/validate, every fallback path, and the
/// context-safety token bound on the generated prompt.
@Suite("ChatSuggestionsProvider")
struct ChatSuggestionsProviderTests {
    private let model = LLMModel(
        id: "afm", displayName: "AFM", supportsTools: false, maxContextTokens: 4_096
    )
    private let fallback = [
        SuggestedChatAction(label: "Explain a verse", message: "Explain a Bible verse to me."),
        SuggestedChatAction(label: "Today's reading", message: "What should I read today?"),
    ]

    private func fake(replying text: String) async -> FakeLLMProvider {
        let fake = FakeLLMProvider(model: model)
        await fake.enqueue([
            .messageStart(id: "m", model: "afm"),
            .contentBlockStart(index: 0, type: .text),
            .textDelta(index: 0, text: text),
            .contentBlockStop(index: 0),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ])
        return fake
    }

    @Test("generated multi-line reply is parsed into actions (label == message)")
    func parsesReply() async {
        let provider = AppleFoundationChatSuggestionsProvider(
            provider: await fake(replying: "Read a psalm\nAsk a question\nPray for peace")
        )
        let result = await provider.suggestions(fallback: fallback)
        #expect(result.map(\.label) == ["Read a psalm", "Ask a question", "Pray for peace"])
        #expect(result.first?.message == "Read a psalm")
    }

    @Test("leading numbering and bullets are stripped")
    func stripsBullets() async {
        let provider = AppleFoundationChatSuggestionsProvider(
            provider: await fake(replying: "1. Read a psalm\n- Ask a question\n• Pray")
        )
        let result = await provider.suggestions(fallback: fallback)
        #expect(result.map(\.label) == ["Read a psalm", "Ask a question", "Pray"])
    }

    @Test("a stream error falls back to the static actions")
    func errorFallsBack() async {
        let fake = FakeLLMProvider(model: model)
        await fake.enqueue([
            .messageStart(id: "m", model: "afm"),
            .error(.providerError(code: "context_window_exceeded", message: "too big")),
        ])
        let result = await AppleFoundationChatSuggestionsProvider(provider: fake)
            .suggestions(fallback: fallback)
        #expect(result == fallback)
    }

    @Test("empty/whitespace reply falls back")
    func emptyFallsBack() async {
        let provider = AppleFoundationChatSuggestionsProvider(provider: await fake(replying: "   \n \n"))
        #expect(await provider.suggestions(fallback: fallback) == fallback)
    }

    @Test("over-long paragraph lines are dropped; falls back when none remain")
    func dropsLongLines() async {
        let provider = AppleFoundationChatSuggestionsProvider(
            provider: await fake(replying: String(repeating: "word ", count: 30))
        )
        #expect(await provider.suggestions(fallback: fallback) == fallback)
    }

    @Test("a generation slower than the timeout falls back")
    func timeoutFallsBack() async {
        let provider = AppleFoundationChatSuggestionsProvider(
            provider: HangingLLMProvider(supportedModels: [model]),
            timeout: .milliseconds(20)
        )
        #expect(await provider.suggestions(fallback: fallback) == fallback)
    }

    @Test("nil provider (AFM unavailable) returns fallback without generating")
    func nilProviderFallsBack() async {
        let result = await AppleFoundationChatSuggestionsProvider(provider: nil)
            .suggestions(fallback: fallback)
        #expect(result == fallback)
    }

    @Test("StaticChatSuggestionsProvider returns the fallback verbatim")
    func staticReturnsFallback() async {
        #expect(await StaticChatSuggestionsProvider().suggestions(fallback: fallback) == fallback)
    }

    @Test("prompt stays under the token bound even with oversized inputs")
    func promptIsTokenBounded() {
        let huge = (0..<200).map { "capability \($0) " + String(repeating: "x", count: 200) }
        let messages = AppleFoundationChatSuggestionsProvider.makePrompt(
            examples: huge, capabilities: huge, count: 3
        )
        #expect(HeuristicTokenEstimator().estimate(messages: messages) < 400)
    }

    @Test("prompt carries examples + capabilities, never schema/JSON")
    func promptContent() {
        let messages = AppleFoundationChatSuggestionsProvider.makePrompt(
            examples: ["Today's reading"], capabilities: ["Search the Bible"], count: 3
        )
        let text = messages.flatMap(\.content).compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined()
        #expect(text.contains("Today's reading"))
        #expect(text.contains("Search the Bible"))
        #expect(!text.contains("{"))
        #expect(!text.contains("parameters"))
    }
}

/// An `LLMProvider` whose stream never yields until cancelled — drives the
/// generation-timeout race so a fast timeout returns the fallback.
private struct HangingLLMProvider: LLMProvider {
    let id = "hang"
    let displayName = "Hang"
    let supportedModels: [LLMModel]

    func stream(
        messages: [LLMMessage], model: LLMModel, tools: [LLMTool], temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
