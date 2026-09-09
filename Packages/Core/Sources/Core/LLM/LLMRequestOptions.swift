import Foundation

/// Optimization hints independent of prompt content; unsupported fields are ignored.
public struct LLMRequestOptions: Sendable, Equatable {
    /// Opaque stable conversation key for cache routing. Use a local row ID, never PII.
    public var conversationCacheKey: String?

    public static let none = LLMRequestOptions()

    public init(conversationCacheKey: String? = nil) {
        self.conversationCacheKey = conversationCacheKey
    }
}
