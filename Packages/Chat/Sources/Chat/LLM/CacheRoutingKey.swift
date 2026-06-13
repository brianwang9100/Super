import Foundation

/// Host-gating for the optional cache-routing affinity hints the OpenAI-family
/// adapters attach. Both OpenAI and xAI auto-cache without any opt-in; these
/// keys only improve which cache shard a conversation's turns land on. They are
/// sent **only** to the exact first-party host that documents them — every
/// other OpenAI-compatible endpoint (DeepSeek, Groq, Ollama, MLX, a Custom
/// proxy) gets a byte-identical request, since a strict or unknown server may
/// reject an unrecognized body field or header.
enum CacheRoutingKey {
    /// OpenAI's `prompt_cache_key` request-body field is honored only here
    /// (Chat Completions and Responses alike).
    static let openAIHost = "api.openai.com"
    /// xAI carries the equivalent as the `x-grok-conv-id` HTTP header, only
    /// against its own host.
    static let xaiHost = "api.x.ai"
    static let xaiHeaderField = "x-grok-conv-id"
}
