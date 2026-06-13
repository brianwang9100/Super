import Foundation

/// Per-request optimization hints that ride alongside a `stream(...)` call but
/// never change the prompt content. Optional and additive: a provider that
/// doesn't recognize a field ignores it and the resulting request is
/// byte-identical to one built without options. Today it carries only a
/// conversation-scoped cache routing key (OpenAI `prompt_cache_key` / xAI
/// `x-grok-conv-id`).
public struct LLMRequestOptions: Sendable, Equatable {
    /// Opaque, stable per-conversation key that improves a provider's cache
    /// routing affinity — turns of one conversation prefer the same cache
    /// shard. The Chat orchestrator passes the local conversation row id
    /// (no PII). `nil` for callers that don't set it.
    public var conversationCacheKey: String?

    /// The empty options every existing call site forwards by default.
    public static let none = LLMRequestOptions()

    public init(conversationCacheKey: String? = nil) {
        self.conversationCacheKey = conversationCacheKey
    }
}
