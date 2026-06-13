import Foundation

/// Host-gating for the optional cache-routing affinity hints the OpenAI-family
/// adapters attach. Both OpenAI and xAI auto-cache without any opt-in; these
/// keys only improve which cache shard a conversation's turns land on. They are
/// sent **only** to the exact first-party host that documents them — every
/// other OpenAI-compatible endpoint (DeepSeek, Groq, Ollama, MLX, a Custom
/// proxy) gets a byte-identical request, since a strict or unknown server may
/// reject an unrecognized body field or header.
enum CacheRoutingKey {
    /// OpenAI honors `prompt_cache_key` in the request body (Chat + Responses).
    static let openAIHost = "api.openai.com"
    /// xAI carries the equivalent as the `x-grok-conv-id` HTTP header.
    static let xaiHost = "api.x.ai"
    static let xaiHeaderField = "x-grok-conv-id"

    /// Where (if anywhere) the conversation cache key rides for a request URL.
    /// One definition shared by both OpenAI adapters so the gating contract
    /// can't drift between the Chat and Responses paths.
    enum Placement: Equatable {
        /// OpenAI: set the `prompt_cache_key` request-body field.
        case promptCacheKeyBody(String)
        /// xAI: set this HTTP header.
        case header(field: String, value: String)
        /// Any other host (or no key): attach nothing.
        case none
    }

    static func placement(for url: URL, conversationCacheKey: String?) -> Placement {
        guard let key = conversationCacheKey, !key.isEmpty else { return .none }
        switch url.host()?.lowercased() {
        case openAIHost: return .promptCacheKeyBody(key)
        case xaiHost: return .header(field: xaiHeaderField, value: key)
        default: return .none
        }
    }
}
