import Core
import Foundation

/// Wire-level Codable shapes for the OpenAI Chat Completions API
/// (Application Programming Interface). Internal — every public surface is
/// kept on `OpenAICompatibleLLMProvider`. Snake_case JSON (JavaScript
/// Object Notation) keys are bridged to camelCase Swift properties via
/// the encoder/decoder's snake-case strategy, so call sites read normally.

/// Request body for `POST {baseURL}/chat/completions`.
struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [OpenAIRequestMessage]
    let stream: Bool
    let temperature: Double
    let tools: [OpenAITool]?
    let streamOptions: StreamOptions?

    /// Mirror of OpenAI's `stream_options` object. Setting `includeUsage`
    /// asks the provider to attach a `usage` object to the final stream
    /// chunk so we can emit `.messageComplete(usage:)` with real numbers
    /// instead of zeroes.
    struct StreamOptions: Encodable {
        let includeUsage: Bool
    }
}

/// One message in the outgoing request. `content` is nil on assistant rows
/// that only carry tool calls; `toolCallId` is set on `tool` rows that
/// return a tool's result.
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

/// Assistant-side tool invocation echoed back into the next request. The
/// `arguments` field is a JSON string per the OpenAI spec — not a nested
/// object — so we stringify the input before placing it here.
///
/// `extraContent` carries Google's `extra_content.google.thought_signature`
/// extension (the encoder's snake_case strategy renders the keys): Gemini's
/// thinking models route through this OpenAI-compat shim and **require** the
/// signature echoed back on the assistant tool call, or the follow-up turn
/// fails with HTTP 400. Omitted (nil) for non-Gemini providers.
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

/// Tool advertisement entry in the request. OpenAI nests the metadata one
/// level deeper than our `LLMTool`, so we project at the call site.
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

/// One streamed chunk decoded from a `data: {...}` SSE (Server-Sent Events)
/// frame. All fields are optional because OpenAI emits the role on the first
/// chunk only, finish reasons on the last chunk only, and usage on a
/// separate trailing chunk when `stream_options.include_usage` is set.
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

/// The actual delta payload. `reasoningContent` is DeepSeek's field name;
/// `reasoning` is the field used by OpenAI's o-series spec — both are
/// surfaced through `LLMStreamEvent.thinkingDelta` so the UI doesn't need
/// to know which dialect produced them.
struct OpenAIDelta: Decodable {
    let role: String?
    let content: String?
    let reasoningContent: String?
    let reasoning: String?
    let toolCalls: [OpenAIToolCallDelta]?
}

/// Streamed tool-call fragment. `index` identifies which tool call this
/// fragment belongs to (the model may stream multiple tool calls
/// interleaved); `function.arguments` arrives as a partial JSON string and
/// is concatenated by the reducer until the call completes.
struct OpenAIToolCallDelta: Decodable {
    let index: Int?
    let id: String?
    let type: String?
    let function: OpenAIFunctionDelta?
    /// Google's `extra_content.google.thought_signature` extension (decoded
    /// via the snake_case key strategy). Present on Gemini thinking models'
    /// tool calls over the OpenAI-compat shim; must be replayed next turn.
    let extraContent: OpenAIExtraContent?

    // Explicit memberwise init (the synthesized one would force every call
    // site to pass `extraContent`); `Decodable` synthesis is unaffected since
    // it keys off `CodingKeys`, not this init.
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
}
