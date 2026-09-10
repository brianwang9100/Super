import Core
import Foundation

/// Uses the stable search tool version that does not require code execution.
enum AnthropicWebSearch {
    static let toolType = "web_search_20250305"
    static let toolName = "web_search"
    /// Caps billable searches per turn.
    static let defaultMaxUses = 5
    static let echoKind = "anthropic.web_search"
}

// MARK: - Request

/// Five-minute cache marker used for stable-system and moving-transcript breakpoints.
struct AnthropicCacheControl: Encodable {
    let type = "ephemeral"
}

/// Array-form system block required to attach cache control.
struct AnthropicSystemBlock: Encodable {
    let text: String
    let cacheControl: AnthropicCacheControl?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
    }
}

struct AnthropicMessagesRequest: Encodable {
    let model: String
    /// Required by the API; derived as `min(maxContextTokens / 4, 4096)`.
    let maxTokens: Int
    let stream: Bool
    /// Block-array form permits caching the stable system prefix.
    let system: [AnthropicSystemBlock]?
    let messages: [AnthropicMessage]
    /// Omitted when extended thinking is enabled — Anthropic rejects any
    /// `temperature` other than 1 in that mode, so the adapter sends none.
    let temperature: Double?
    let tools: [AnthropicTool]?
    let thinking: Thinking?

    enum CodingKeys: String, CodingKey {
        case model, stream, system, messages, temperature, tools, thinking
        case maxTokens = "max_tokens"
    }

    /// Extended-thinking toggle. `budget_tokens` must be ≥ 1024 and strictly
    /// less than `max_tokens` (API constraint).
    struct Thinking: Encodable {
        let type: String
        let budgetTokens: Int

        enum CodingKeys: String, CodingKey {
            case type
            case budgetTokens = "budget_tokens"
        }
    }
}

/// Adjacent same-role turns must be merged to satisfy strict role alternation.
struct AnthropicMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]
}

enum AnthropicContentBlock: Encodable {
    case text(String)
    /// A replayed extended-thinking block. The Messages API requires the
    /// last assistant turn of a tool loop to start with its original
    /// `thinking` block, verbatim, including the streamed signature.
    case thinking(thinking: String, signature: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    case webSearchToolResult(toolUseID: String, results: [WebSearchResultEcho])
    /// Adds the moving cache breakpoint to the last transcript block.
    indirect case cached(AnthropicContentBlock)

    /// A single replayed `web_search_result`, carrying the verbatim
    /// `encrypted_content` Anthropic requires to keep the citation valid.
    struct WebSearchResultEcho: Encodable {
        let url: String
        let title: String
        let encryptedContent: String
        let pageAge: String?

        enum CodingKeys: String, CodingKey {
            case type, url, title
            case encryptedContent = "encrypted_content"
            case pageAge = "page_age"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("web_search_result", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encode(title, forKey: .title)
            try container.encode(encryptedContent, forKey: .encryptedContent)
            try container.encodeIfPresent(pageAge, forKey: .pageAge)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content, thinking, signature
        case toolUseID = "tool_use_id"
        case isError = "is_error"
        case cacheControl = "cache_control"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cached(let inner):
            // JSONEncoder shares storage across keyed containers, allowing the marker to merge.
            try inner.encode(to: encoder)
            try container.encode(AnthropicCacheControl(), forKey: .cacheControl)
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let thinking, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
            try container.encode(signature, forKey: .signature)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        case .webSearchToolResult(let toolUseID, let results):
            try container.encode("web_search_tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(results, forKey: .content)
        }
    }
}

/// A tool advertised in the request. `webSearch` is the native server tool;
/// `function` carries a client tool's JSON-Schema parameters under
/// `input_schema` (Anthropic's name for it).
enum AnthropicTool: Encodable {
    case webSearch(maxUses: Int)
    case function(name: String, description: String, inputSchema: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, name, description
        case maxUses = "max_uses"
        case inputSchema = "input_schema"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .webSearch(let maxUses):
            try container.encode(AnthropicWebSearch.toolType, forKey: .type)
            try container.encode(AnthropicWebSearch.toolName, forKey: .name)
            try container.encode(maxUses, forKey: .maxUses)
        case .function(let name, let description, let inputSchema):
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encode(inputSchema, forKey: .inputSchema)
        }
    }
}

// MARK: - Stream

/// Typed SSE event whose optional payload is interpreted by `type`.
struct AnthropicStreamEvent: Decodable {
    let type: String
    let index: Int?
    let message: MessageStart?
    let contentBlock: ContentBlock?
    let delta: Delta?
    let usage: Usage?
    let error: ErrorBody?

    struct MessageStart: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        /// Prompt tokens written to / read from the 5-minute ephemeral cache.
        /// Both land on the `message_start` usage; `.convertFromSnakeCase` maps
        /// `cache_creation_input_tokens` / `cache_read_input_tokens`.
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
    }

    /// A starting content block. `text`/`thinking` open prose; `tool_use` is a
    /// client tool; `server_tool_use` (name `web_search`) is the search call;
    /// `web_search_tool_result` carries the result set (fully present at start,
    /// not streamed).
    struct ContentBlock: Decodable {
        let type: String?
        let id: String?
        let name: String?
        let toolUseId: String?
        let content: [WebSearchResult]?
    }

    struct WebSearchResult: Decodable {
        let type: String?
        let url: String?
        let title: String?
        let encryptedContent: String?
        let pageAge: String?
    }

    /// The `delta` payload, reused across `content_block_delta` (text /
    /// thinking / tool-arg / citation sub-types) and `message_delta`
    /// (`stop_reason`).
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        /// `signature_delta` payload — the thinking block's integrity
        /// signature, required verbatim on replay.
        let signature: String?
        let partialJson: String?
        let citation: Citation?
        let stopReason: String?
    }

    /// A `citations_delta` payload (`web_search_result_location`).
    struct Citation: Decodable {
        let type: String?
        let url: String?
        let title: String?
        let citedText: String?
        let encryptedIndex: String?
    }

    struct ErrorBody: Decodable {
        let type: String?
        let message: String?
    }
}
