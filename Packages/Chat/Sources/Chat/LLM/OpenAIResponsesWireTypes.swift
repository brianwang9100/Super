import Core
import Foundation

// Wire-level Codable shapes for the OpenAI Responses API (Application
// Programming Interface) — `POST /v1/responses`. Internal; every public
// surface stays on `OpenAIResponsesLLMProvider`.
//
// The Responses API differs from Chat Completions in three ways this file
// encodes: the system prompt rides a top-level `instructions` string (not a
// `system` message), the conversation is an `input` array of typed items
// (messages, function calls, function-call outputs), and `web_search` is a
// first-class server tool (`{"type":"web_search"}`) rather than a `function`.
// Request keys are written explicitly (no snake-case strategy) because the
// heterogeneous `input`/`tools` items hand-roll `encode(to:)`.

// MARK: - Request

/// Request body for `POST {baseURL}/responses`.
struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: [OpenAIResponsesInputItem]
    /// System prompt. The Responses API carries it here, not as a message.
    let instructions: String?
    let stream: Bool
    let temperature: Double
    let tools: [OpenAIResponsesTool]?

    enum CodingKeys: String, CodingKey {
        case model, input, instructions, stream, temperature, tools
    }
}

/// One item in the Responses `input` array. The API models a turn as a
/// sequence of typed items rather than role-tagged messages, so tool calls
/// and their outputs are first-class siblings of plain messages.
enum OpenAIResponsesInputItem: Encodable {
    /// A user or assistant text message.
    case message(role: String, text: String)
    /// An assistant-issued function (client tool) call, echoed back into
    /// history. `argumentsJSON` is a JSON string per the API.
    case functionCall(callID: String, name: String, argumentsJSON: String)
    /// The result of a prior function call, correlated by `callID`.
    case functionCallOutput(callID: String, output: String)

    private enum CodingKeys: String, CodingKey {
        case type, role, content, callID = "call_id", name, arguments, output
    }

    /// Content block inside a `message` item. User text is `input_text`;
    /// assistant text is `output_text` (the API rejects the wrong pairing).
    private struct ContentBlock: Encodable {
        let type: String
        let text: String
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let text):
            try container.encode("message", forKey: .type)
            try container.encode(role, forKey: .role)
            let blockType = role == "assistant" ? "output_text" : "input_text"
            try container.encode([ContentBlock(type: blockType, text: text)], forKey: .content)
        case .functionCall(let callID, let name, let argumentsJSON):
            try container.encode("function_call", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(argumentsJSON, forKey: .arguments)
        case .functionCallOutput(let callID, let output):
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(output, forKey: .output)
        }
    }
}

/// A tool advertised in the request. `web_search` is the native server tool;
/// `function` carries a client tool's JSON-Schema parameters (flattened, not
/// nested under a `function` key the way Chat Completions does).
enum OpenAIResponsesTool: Encodable {
    case webSearch
    case function(name: String, description: String, parameters: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, name, description, parameters
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .webSearch:
            try container.encode("web_search", forKey: .type)
        case .function(let name, let description, let parameters):
            try container.encode("function", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encode(parameters, forKey: .parameters)
        }
    }
}

// MARK: - Stream

/// One decoded Responses streaming event. The Responses stream is a typed SSE
/// (Server-Sent Events) sequence — each frame's JSON carries a `type` string
/// (mirroring the SSE `event:` name) plus a payload that varies by type. All
/// payload fields are optional; the reducer keys on `type` and reads only the
/// fields that type populates. Decoded with `.convertFromSnakeCase`, so
/// `item_id`/`start_index`/`input_tokens` arrive as camelCase.
struct OpenAIResponsesStreamEvent: Decodable {
    let type: String
    /// Text/reasoning delta payload (`response.output_text.delta`,
    /// `response.reasoning_summary_text.delta`, function-argument deltas).
    let delta: String?
    /// References the streaming item a delta belongs to — the `output_item`'s
    /// own id, used to key the function-call argument accumulator.
    let itemId: String?
    /// Present on `response.output_item.added`.
    let item: Item?
    /// Present on `response.output_text.annotation.added`.
    let annotation: Annotation?
    /// Present on `response.created` / `response.completed`.
    let response: ResponseEnvelope?
    /// Error payload (`response.error` / `error`).
    let code: String?
    let message: String?

    /// A streamed output item header. `web_search_call` carries the query in
    /// `action`; `function_call` carries the client-tool name + correlation id.
    struct Item: Decodable {
        let type: String?
        let id: String?
        let callId: String?
        let name: String?
        let action: Action?

        struct Action: Decodable {
            let query: String?
        }
    }

    /// A citation annotation attached to a span of output text.
    struct Annotation: Decodable {
        let type: String?
        let url: URL?
        let title: String?
        let startIndex: Int?
        let endIndex: Int?
    }

    /// The response object on `created` (id/model) and `completed` (usage).
    struct ResponseEnvelope: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
        }
    }
}
