import Core
import Foundation

struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [OpenAIRequestMessage]
    let stream: Bool
    let temperature: Double
    let tools: [OpenAITool]?
    let streamOptions: StreamOptions?
    /// Host-gated to OpenAI because compatible endpoints may reject unknown fields.
    let promptCacheKey: String?

    struct StreamOptions: Encodable {
        let includeUsage: Bool
    }
}

struct OpenAIRequestMessage: Encodable {
    let role: String
    let content: String?
    let toolCalls: [OutgoingToolCall]?
    let toolCallId: String?

    init(
        role: String,
        content: String? = nil,
        toolCalls: [OutgoingToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

/// Gemini-compatible calls must replay Google's opaque thought signature.
struct OutgoingToolCall: Encodable {
    let id: String
    let type: String
    let function: OutgoingFunction
    let extraContent: OutgoingExtraContent?

    init(id: String, name: String, argumentsJSON: String, thoughtSignature: String? = nil) {
        self.id = id
        self.type = "function"
        self.function = OutgoingFunction(name: name, arguments: argumentsJSON)
        self.extraContent = thoughtSignature.map { OutgoingExtraContent(thoughtSignature: $0) }
    }
}

struct OutgoingFunction: Encodable {
    let name: String
    let arguments: String
}

/// `extra_content: { "google": { "thought_signature": "..." } }` — the
/// OpenAI-Realtime-style extension Google uses to carry Gemini-specific fields
/// over the OpenAI-compatible endpoint.
struct OutgoingExtraContent: Encodable {
    let google: Google

    init(thoughtSignature: String) {
        self.google = Google(thoughtSignature: thoughtSignature)
    }

    struct Google: Encodable {
        let thoughtSignature: String
    }
}

struct OpenAITool: Encodable {
    let type: String
    let function: OpenAIFunctionDefinition

    init(function: OpenAIFunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

struct OpenAIFunctionDefinition: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

/// Partial SSE chunk; usage may arrive in a separate trailing chunk.
struct OpenAIStreamChunk: Decodable {
    let id: String?
    let model: String?
    let choices: [OpenAIStreamChoice]?
    let usage: OpenAIUsage?
}

struct OpenAIStreamChoice: Decodable {
    let index: Int?
    let delta: OpenAIDelta?
    let finishReason: String?
}

/// Supports both DeepSeek and OpenAI reasoning field names.
struct OpenAIDelta: Decodable {
    let role: String?
    let content: String?
    let reasoningContent: String?
    let reasoning: String?
    let toolCalls: [OpenAIToolCallDelta]?
    var refusal: String?
}

/// `index` keys interleaved calls whose JSON arguments arrive in fragments.
struct OpenAIToolCallDelta: Decodable {
    let index: Int?
    let id: String?
    let type: String?
    let function: OpenAIFunctionDelta?
    /// Google's `extra_content.google.thought_signature` extension (decoded
    /// via the snake_case key strategy). Present on Gemini thinking models'
    /// tool calls over the OpenAI-compat shim; must be replayed next turn.
    let extraContent: OpenAIExtraContent?

    init(
        index: Int? = nil,
        id: String? = nil,
        type: String? = nil,
        function: OpenAIFunctionDelta? = nil,
        extraContent: OpenAIExtraContent? = nil
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
        self.extraContent = extraContent
    }
}

struct OpenAIFunctionDelta: Decodable {
    let name: String?
    let arguments: String?
}

/// Decoded `extra_content` extension envelope. Only the Gemini
/// `google.thought_signature` field is modeled; anything else is ignored.
struct OpenAIExtraContent: Decodable {
    let google: Google?

    struct Google: Decodable {
        let thoughtSignature: String?
    }
}

struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    /// Cache breakdown of `promptTokens`. OpenAI and xAI both report cached
    /// prompt tokens here (a *subset* already counted in `promptTokens`);
    /// `.convertFromSnakeCase` maps `prompt_tokens_details.cached_tokens`.
    /// Absent on providers that don't surface caching (Ollama, MLX, etc.).
    let promptTokensDetails: PromptTokensDetails?

    struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?
    }

    init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        promptTokensDetails: PromptTokensDetails? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.promptTokensDetails = promptTokensDetails
    }
}
