import Core
import Foundation

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

    /// Skip empty assistant turns at the caller. Read title settings afresh per request;
    /// nil means preserve the existing title after disabled/unavailable/failed or empty generation.
    public func generate(
        userText: String,
        assistantText: String
    ) async -> String? {
        guard await settingsStore.isTitleSummarizationEnabled() else { return nil }

        let available = SelectableModel.from(providers: await llmProviderRegistry.allProviders())
        guard let chosen = Self.resolveTitleModel(
            selectedRecordId: await settingsStore.titleModelId(),
            available: available
        ) else { return nil }
        // Record identity distinguishes endpoints sharing an upstream model ID.
        guard let provider = await llmProviderRegistry.provider(id: chosen.recordId) else { return nil }

        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: Self.systemPrompt),
            LLMMessage(role: .user, text: Self.formatExchange(user: userText, assistant: assistantText)),
        ]

        var accumulated = ""
        do {
            let stream = provider.stream(
                messages: messages,
                model: chosen.model,
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

    /// Nil selects available AFM. Explicit IDs resolve by record ID, then legacy model ID;
    /// an unresolved explicit selection disables titling instead of falling back to AFM.
    static func resolveTitleModel(
        selectedRecordId: String?,
        available: [SelectableModel]
    ) -> SelectableModel? {
        if let selectedRecordId {
            if let match = available.first(where: { $0.recordId == selectedRecordId }) {
                return match
            }
            return available.first { $0.model.id == selectedRecordId }
        }
        return available.first { $0.model.id == AppleFoundationLLMProvider.defaultModelID }
    }

    static let systemPrompt = """
    You generate concise titles for chat conversations. Given the first user message and the assistant's first reply, respond with a 3 to 6 word title that captures the conversation's topic. Respond with only the title text — no quotes, no surrounding punctuation, no explanation.
    """

    /// Qwen3's /no_think hint avoids generating a reasoning trace before the short title.
    static func formatExchange(user: String, assistant: String) -> String {
        "User: \(user)\n\nAssistant: \(assistant)\n\n/no_think"
    }

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
