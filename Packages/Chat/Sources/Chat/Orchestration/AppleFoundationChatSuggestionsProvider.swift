import Core
import Foundation

/// Generates empty-state chat starters on-device via Apple Foundation Models,
/// falling back to the static applet actions on unavailability/error/timeout.
///
/// Context-safety: this builds its **own minimal prompt** (a single user
/// message of examples + compact capabilities) and never goes through
/// `ContextAssembler` or the chat system prompt — AFM's ~4k-token window can't
/// absorb the full chat persona, so the suggestion call keeps its own tiny
/// budget. `makePrompt` caps and truncates its inputs so the prompt stays small
/// regardless of how many examples/capabilities it's handed.
public struct AppleFoundationChatSuggestionsProvider: ChatSuggestionsProvider {
    /// The AFM provider, or `nil` when Apple Intelligence is unavailable — in
    /// which case `suggestions` returns the fallback without any generation.
    private let provider: (any LLMProvider)?
    private let capabilities: [String]
    private let count: Int
    private let timeout: Duration

    public init(
        provider: (any LLMProvider)?,
        capabilities: [String] = [],
        count: Int = 3,
        timeout: Duration = .seconds(8)
    ) {
        self.provider = provider
        self.capabilities = capabilities
        self.count = count
        self.timeout = timeout
    }

    public func suggestions(fallback: [SuggestedChatAction]) async -> [SuggestedChatAction] {
        guard let provider, let model = provider.supportedModels.first else { return fallback }
        let messages = Self.makePrompt(
            examples: fallback.map(\.label),
            capabilities: capabilities,
            count: count
        )
        do {
            let text = try await generate(messages, model: model, provider: provider)
            let parsed = Self.parse(text, count: count)
            return parsed.isEmpty ? fallback : parsed
        } catch {
            return fallback
        }
    }

    /// Consume the provider's stream to completion (accumulating text deltas),
    /// racing it against `timeout`. A timeout or any stream error throws, which
    /// `suggestions(fallback:)` maps to the static fallback.
    private func generate(
        _ messages: [LLMMessage],
        model: LLMModel,
        provider: any LLMProvider
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for try await event in provider.stream(
                    messages: messages, model: model, tools: [], temperature: 0.8
                ) {
                    switch event {
                    case .textDelta(_, let delta): text += delta
                    case .error(let error): throw error
                    default: break
                    }
                }
                return text
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SuggestionTimeout.timedOut
            }
            // Whichever finishes first wins; cancel the loser on the way out.
            let result = try await group.next() ?? ""
            group.cancelAll()
            return result
        }
    }

    /// Build the single-message generation prompt. Pure + bounded: examples and
    /// capabilities are capped in count and per-line length so the estimated
    /// token size stays small no matter how large the inputs are.
    static func makePrompt(examples: [String], capabilities: [String], count: Int) -> [LLMMessage] {
        let exampleLines = examples.prefix(6).map { String($0.prefix(40)) }
        let capabilityLines = capabilities.prefix(6).map { String($0.prefix(80)) }

        var text = "Suggest \(count) very short prompts (max 5 words each) a user might tap to start a chat."
        if !capabilityLines.isEmpty {
            text += " The assistant can: \(capabilityLines.joined(separator: "; "))."
        }
        if !exampleLines.isEmpty {
            text += " Match the style of these examples: \(exampleLines.joined(separator: "; "))."
        }
        text += " Reply with exactly \(count) lines, one prompt per line, no numbering or extra text."
        return [LLMMessage(role: .user, text: text)]
    }

    /// Parse the model's reply into actions: one short line each, with leading
    /// bullets/numbering stripped, blanks and over-long lines (paragraph dumps)
    /// dropped, capped to `count`. The label is also the message sent.
    static func parse(_ text: String, count: Int) -> [SuggestedChatAction] {
        text
            .split(whereSeparator: \.isNewline)
            .map { line in
                line
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(
                        of: #"^\s*(?:[-*•]|\d+[.)])\s+"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            .filter { !$0.isEmpty && $0.count <= 48 }
            .prefix(count)
            .map { SuggestedChatAction(label: $0, message: $0) }
    }
}

/// Thrown by the generation timeout race; mapped to the static fallback.
private enum SuggestionTimeout: Error { case timedOut }
