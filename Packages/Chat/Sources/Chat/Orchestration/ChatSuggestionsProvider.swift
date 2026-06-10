import Core

/// Resolves the empty-state chat-starter suggestions. The default production
/// impl tries on-device Apple Foundation Models generation and falls back to
/// the static applet-contributed actions; the `Static` impl below is the
/// no-generation default used by previews, tests, and devices without Apple
/// Intelligence.
public protocol ChatSuggestionsProvider: Sendable {
    /// Resolve the suggestions to show. Implementations that generate must
    /// return `fallback` on unavailability, error, timeout, or an empty/invalid
    /// result — so the caller always gets a usable, non-empty list when
    /// `fallback` is non-empty.
    func suggestions(fallback: [SuggestedChatAction]) async -> [SuggestedChatAction]
}

/// No generation — returns the static `fallback` verbatim. The default wired
/// into `ChatScreenViewModel`, so any path that doesn't inject a generating
/// provider (previews, unit tests, AFM-absent devices) keeps PR1 behavior.
public struct StaticChatSuggestionsProvider: ChatSuggestionsProvider {
    public init() {}

    public func suggestions(fallback: [SuggestedChatAction]) async -> [SuggestedChatAction] {
        fallback
    }
}
