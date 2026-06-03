import Core
import Foundation

/// Synthesizes a short, human-readable title for a chat conversation from
/// its first user/assistant exchange. Wraps the LLM (Large Language Model)
/// provider's existing streaming API — no separate non-streaming codepath —
/// and returns the cleaned title once the stream completes.
///
/// The summarizer is user-configurable and independent of the conversation's
/// active model: a master toggle (`ChatSettings.summarizeTitlesEnabled`) and
/// a model selection (`ChatSettings.titleModelId`, `nil` ⇒ automatic → the
/// Apple Foundation Model when available). `generate` reads both fresh on
/// each call so a settings change takes effect without restarting the chat.
///
/// Returns `nil` when titling is disabled, no model resolves (AFM
/// unavailable / the chosen model was deleted / no provider serves it), the
/// request errors out, or the cleaned text is empty. Callers treat `nil` as
/// "leave the existing title alone" (the truncated-message fallback stands)
/// rather than overwriting it with an empty string.
public struct TitleGenerator: Sendable {
    private let llmProviderRegistry: LLMProviderRegistry
    private let settingsStore: ChatSettingsStore
    private let maxLength: Int

    public init(
        llmProviderRegistry: LLMProviderRegistry,
        settingsStore: ChatSettingsStore,
        maxLength: Int = 60
    ) {
        self.llmProviderRegistry = llmProviderRegistry
        self.settingsStore = settingsStore
        self.maxLength = maxLength
    }

    /// Generate a title from the first turn's text. Caller is responsible
    /// for skipping empty assistant turns (tool-only, errored). Resolves the
    /// configured summarizer model and its provider internally; returns `nil`
    /// (no titling) when the toggle is off or no usable model resolves.
    public func generate(
        userText: String,
        assistantText: String
    ) async -> String? {
        guard await settingsStore.isTitleSummarizationEnabled() else { return nil }

        let available = await llmProviderRegistry.allProviders().flatMap(\.supportedModels)
        guard let model = Self.resolveTitleModel(
            selectedModelId: await settingsStore.titleModelId(),
            available: available
        ) else { return nil }
        guard let provider = await llmProviderRegistry.provider(forModelId: model.id) else { return nil }

        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: Self.systemPrompt),
            LLMMessage(role: .user, text: Self.formatExchange(user: userText, assistant: assistantText)),
        ]

        var accumulated = ""
        do {
            let stream = provider.stream(
                messages: messages,
                model: model,
                tools: [],
                temperature: 0.4
            )
            for try await event in stream {
                switch event {
                case .textDelta(_, let chunk):
                    accumulated += chunk
                case .error(let err):
                    throw err
                default:
                    break
                }
            }
        } catch {
            return nil
        }

        return Self.clean(accumulated, maxLength: maxLength)
    }

    /// Resolve which model titles a chat from the persisted selection and the
    /// currently-available models. `nil` selection ⇒ "automatic": the Apple
    /// Foundation Model if it's available (its `LLMModel` is only present when
    /// the provider registered, i.e. AFM is supported on this device), else
    /// `nil`. An explicit id ⇒ that model when still available, else `nil` (the
    /// model was deleted — fall back to no titling rather than reverting to
    /// AFM). The enabled/disabled gate is the caller's; this only picks the
    /// model.
    static func resolveTitleModel(selectedModelId: String?, available: [LLMModel]) -> LLMModel? {
        if let selectedModelId {
            return available.first { $0.id == selectedModelId }
        }
        return available.first { $0.id == AppleFoundationLLMProvider.defaultModelID }
    }

    /// System prompt sent on every title call. Pinned to a static so the
    /// shape is exercised by the unit test rather than only at runtime.
    static let systemPrompt = """
    You generate concise titles for chat conversations. Given the first user message and the assistant's first reply, respond with a 3 to 6 word title that captures the conversation's topic. Respond with only the title text — no quotes, no surrounding punctuation, no explanation.
    """

    /// Format the first turn for the title prompt. The trailing
    /// `/no_think` is a Qwen3 chat-template soft-switch that suppresses
    /// the model's reasoning chain — without it, Qwen3 streams several
    /// seconds of thinking tokens before the title text. For non-Qwen
    /// models the literal token is harmless trailing content. Replace
    /// with a structured `reasoning_effort` request field once a
    /// non-Qwen reasoning provider is on the BYOK roster.
    static func formatExchange(user: String, assistant: String) -> String {
        "User: \(user)\n\nAssistant: \(assistant)\n\n/no_think"
    }

    /// Trim, strip wrapping quotes, drop trailing sentence punctuation, and
    /// cap to `maxLength`. Returns `nil` for empty input so the caller can
    /// distinguish "model said nothing useful" from "use this title."
    static func clean(_ raw: String, maxLength: Int) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripWrappingQuotes(text)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxLength {
            text = String(text.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "`"]
        var s = text
        while let first = s.first, quotes.contains(first) { s.removeFirst() }
        while let last = s.last, quotes.contains(last) { s.removeLast() }
        return s
    }
}
