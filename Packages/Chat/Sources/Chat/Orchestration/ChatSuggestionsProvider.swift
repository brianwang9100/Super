import Core

public protocol ChatSuggestionsProvider: Sendable {
    /// Generating implementations return fallback on unavailability, failure, timeout, or unusable output.
    func suggestions(fallback: [SuggestedChatAction]) async -> [SuggestedChatAction]
}

public struct StaticChatSuggestionsProvider: ChatSuggestionsProvider {
    public init() {}

    public func suggestions(fallback: [SuggestedChatAction]) async -> [SuggestedChatAction] {
        fallback
    }
}
