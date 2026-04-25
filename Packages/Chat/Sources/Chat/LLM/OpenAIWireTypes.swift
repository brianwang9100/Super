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
struct OutgoingToolCall: Encodable {
    let id: String
    let type: String
    let function: OutgoingFunction

    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.type = "function"
        self.function = OutgoingFunction(name: name, arguments: argumentsJSON)
    }
}

struct OutgoingFunction: Encodable {
    let name: String
    let arguments: String
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
}

struct OpenAIFunctionDelta: Decodable {
    let name: String?
    let arguments: String?
}

struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
}
