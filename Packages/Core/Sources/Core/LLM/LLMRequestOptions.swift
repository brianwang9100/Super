import Foundation

/// Local validation and cache hints that never alter prompt content. Providers ignore unsupported options.
public struct LLMRequestOptions: Sendable, Equatable {
    /// Opaque stable conversation key for cache routing. Use a local row ID, never PII.
    public var conversationCacheKey: String?

    /// Requires native completion evidence; supporting adapters emit an error before their terminal event
    /// for truncated or unverified output. Validation adds no wire parameter.
    public var requiresCompleteResponse: Bool

    public static let none = LLMRequestOptions()

    public init(conversationCacheKey: String? = nil, requiresCompleteResponse: Bool = false) {
        self.conversationCacheKey = conversationCacheKey
        self.requiresCompleteResponse = requiresCompleteResponse
    }
}
