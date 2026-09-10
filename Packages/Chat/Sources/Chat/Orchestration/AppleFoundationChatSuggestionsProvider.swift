import Core
import Foundation

/// Use a separate bounded prompt: AFM's small window cannot fit the full Chat persona.
/// Unavailability, errors, and timeouts return the supplied static actions.
public struct AppleFoundationChatSuggestionsProvider: ChatSuggestionsProvider {
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
            let result = try await group.next() ?? ""
            group.cancelAll()
            return result
        }
    }

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

private enum SuggestionTimeout: Error { case timedOut }
