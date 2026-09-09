import Foundation

/// Per-request normalization and optimization hints that ride alongside a `stream(...)` call but
/// never change the prompt content. Optional and additive: a provider that
/// doesn't recognize a field ignores it and the resulting request is
/// byte-identical to one built without options. Completion validation is
/// performed locally and never adds a wire parameter or changes the prompt.
public struct LLMRequestOptions: Sendable, Equatable {
    /// Opaque, stable per-conversation key that improves a provider's cache
    /// routing affinity — turns of one conversation prefer the same cache
    /// shard. The Chat orchestrator passes the local conversation row id
    /// (no PII). `nil` for callers that don't set it.
    public var conversationCacheKey: String?

    /// Require native evidence of successful completion. Supporting adapters emit
    /// an error before their terminal event for truncated or unverified output.
    /// Defaults to false to preserve existing Chat and bulk stream behavior.
    public var requiresCompleteResponse: Bool

    /// The empty options every existing call site forwards by default.
    public static let none = LLMRequestOptions()

    /// Creates local completion requirements and optional cache routing hints.
    public init(conversationCacheKey: String? = nil, requiresCompleteResponse: Bool = false) {
        self.conversationCacheKey = conversationCacheKey
        self.requiresCompleteResponse = requiresCompleteResponse
    }
}
