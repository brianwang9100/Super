import Core
import Foundation

// MARK: - Request

struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: [OpenAIResponsesInputItem]
    /// System prompt. The Responses API carries it here, not as a message.
    let instructions: String?
    let stream: Bool
    let temperature: Double
    let tools: [OpenAIResponsesTool]?
    /// Host-gated to OpenAI because compatible endpoints may reject unknown fields.
    let promptCacheKey: String?

    enum CodingKeys: String, CodingKey {
        case model, input, instructions, stream, temperature, tools
        case promptCacheKey = "prompt_cache_key"
    }
}

enum OpenAIResponsesInputItem: Encodable {
    case message(role: String, text: String)
    /// Stateless replay correlates by `call_id`; the server item ID is not persisted.
    case functionCall(callID: String, name: String, argumentsJSON: String)
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

/// Typed SSE event whose optional payload is interpreted by `type`.
struct OpenAIResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    /// References the streaming item a delta belongs to — the `output_item`'s
    /// own id, used to key the function-call argument accumulator.
    let itemId: String?
    let item: Item?
    let annotation: Annotation?
    let response: ResponseEnvelope?
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

    /// Kept as a string so one malformed URL cannot discard the entire SSE event.
    struct Annotation: Decodable {
        let type: String?
        let url: String?
        let title: String?
        let startIndex: Int?
        let endIndex: Int?
    }

    struct ResponseEnvelope: Decodable {
        let status: String?
        let id: String?
        let model: String?
        let usage: Usage?

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            /// Cache breakdown of `inputTokens` (a *subset* already counted in
            /// it). The Responses API nests it under `input_tokens_details`
            /// (vs. Chat Completions' `prompt_tokens_details`).
            let inputTokensDetails: InputTokensDetails?

            struct InputTokensDetails: Decodable {
                let cachedTokens: Int?
            }
        }
    }
}
