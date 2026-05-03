import Core
import Foundation

/// Synthesizes a short, human-readable title for a chat conversation from
/// its first user/assistant exchange. Wraps the active LLM (Large Language
/// Model) provider's existing streaming API — no separate non-streaming
/// codepath — and returns the cleaned title once the stream completes.
///
/// Returns `nil` when the registry has no active provider, the request
/// errors out, or the cleaned text is empty. Callers treat `nil` as "leave
/// the existing title alone" rather than overwriting it with an empty
/// string.
public struct TitleGenerator: Sendable {
    private let llmProviderRegistry: LLMProviderRegistry
    private let maxLength: Int

    public init(
        llmProviderRegistry: LLMProviderRegistry,
        maxLength: Int = 60
    ) {
        self.llmProviderRegistry = llmProviderRegistry
        self.maxLength = maxLength
    }

    /// Generate a title from the first turn's text. Caller is responsible
    /// for skipping empty assistant turns (tool-only, errored).
    public func generate(
        userText: String,
        assistantText: String,
        model: LLMModel
    ) async -> String? {
        let provider: any LLMProvider
        do {
            provider = try await llmProviderRegistry.requireActive()
        } catch {
            return nil
        }

        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: Self.systemPrompt),
            LLMMessage(role: .user, text: Self.formatExchange(user: userText, assistant: assistantText))
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
