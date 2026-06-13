import Core
import Foundation

// Wire-level Codable shapes for the Anthropic Messages API (Application
// Programming Interface) — `POST /v1/messages`. Internal; every public surface
// stays on `AnthropicNativeLLMProvider`.
//
// The Messages API differs from OpenAI Chat Completions in the ways this file
// encodes: the system prompt is a top-level `system` string (not a message),
// every message's `content` is an array of typed blocks, tool *results* ride a
// `user`-role message (not a dedicated `tool` role), and `web_search` is a
// server tool whose results carry an opaque `encrypted_content` that must be
// echoed back verbatim on later turns. Request keys are written explicitly
// (no snake-case strategy) because several blocks hand-roll `encode(to:)`.

/// Anthropic web-search server tool — naming + version in one place.
///
/// Ships the **stable `web_search_20250305`** version (PR3b decision): unlike
/// the newer `web_search_20260209`, it is not model-gated and does **not**
/// require the server-side code-execution tool to be enabled alongside — which
/// keeps the public App Store surface (SuperBible) minimal and avoids depending
/// on a tool-type string we can't verify without the live API. Bumping the
/// version later is a one-line change here. Docs:
/// https://docs.anthropic.com/en/docs/build-with-claude/tool-use/web-search-tool
enum AnthropicWebSearch {
    static let toolType = "web_search_20250305"
    static let toolName = "web_search"
    /// Cap on searches per turn. Anthropic bills per search, so a small bound
    /// matches the cost-conscious posture the gate (PR4) enforces.
    static let defaultMaxUses = 5
    /// `ProviderEcho.kind` discriminator for echoes this adapter produces.
    static let echoKind = "anthropic.web_search"
}

// MARK: - Request

/// `cache_control: {"type": "ephemeral"}` — the 5-minute prompt-cache
/// breakpoint marker. No `ttl`: the 1-hour tier costs 2× on writes, and reads
/// refresh the 5-minute window anyway, so active conversations stay warm.
/// Attached to a `system` block and to the last content block of the last
/// message (the "moving" breakpoint) so the stable prefix + tools and the
/// growing transcript are both cacheable.
struct AnthropicCacheControl: Encodable {
    let type = "ephemeral"
}

/// One block of the top-level `system` array. The Messages API accepts either
/// a bare string or an array of typed text blocks; only the array form can
/// carry a `cache_control` marker, which is why the request models `system` as
/// `[AnthropicSystemBlock]?`.
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

/// Request body for `POST {baseURL}/messages`.
struct AnthropicMessagesRequest: Encodable {
    let model: String
    /// Required by the API. Derived as `min(maxContextTokens/4, 4096)` (§0 #7).
    let maxTokens: Int
    let stream: Bool
    /// System prompt. The Messages API carries it here, not as a message; the
    /// block-array form lets the stable prefix block carry a `cache_control`
    /// marker. Omitted entirely (nil) when there's no system text.
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

/// One message in the request `messages` array. Anthropic groups all blocks of
/// a turn under a single role-tagged message; `AnthropicNativeLLMProvider`
/// merges adjacent same-role Core messages to satisfy the strict
/// user/assistant alternation the API requires.
struct AnthropicMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]
}

/// One content block inside a message. `webSearchToolResult` is the replay
/// carrier — reconstructed from a prior turn's stored echoes so citations stay
/// valid (see ``AnthropicNativeLLMProvider`` translate).
enum AnthropicContentBlock: Encodable {
    case text(String)
    /// A replayed extended-thinking block. The Messages API requires the
    /// last assistant turn of a tool loop to start with its original
    /// `thinking` block, verbatim, including the streamed signature.
    case thinking(thinking: String, signature: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    case webSearchToolResult(toolUseID: String, results: [WebSearchResultEcho])
    /// Moving cache breakpoint: wraps another block, encoding it verbatim plus
    /// a merged `cache_control` marker. Used on the last content block of the
    /// last message so the whole transcript prefix is cacheable; `indirect`
    /// because the case stores another `AnthropicContentBlock`.
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
            // Encode the inner block's keys into this same keyed container,
            // then merge the marker. Two `container(keyedBy:)` calls on one
            // encoder write to the same underlying storage, so the result is
            // the inner block's JSON with a `cache_control` field added. This
            // merge relies on Foundation's `JSONEncoder` (the only codec these
            // wire types ever pass through, pinned by a contract unit test); a
            // custom Encoder that allocates fresh storage per
            // `container(keyedBy:)` would drop the inner keys — decode-and-
            // re-encode instead if this type ever migrates to another codec.
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

/// One decoded Messages streaming event. The stream is a typed SSE
/// (Server-Sent Events) sequence — each frame's JSON carries a `type` string
/// (mirroring the SSE `event:` name) plus a payload that varies by type. All
/// payload fields are optional; the reducer keys on `type` and reads only the
/// fields that type populates. Decoded with `.convertFromSnakeCase`, so
/// `partial_json`/`encrypted_content`/`tool_use_id`/`input_tokens` arrive as
/// camelCase. Docs:
/// https://docs.anthropic.com/en/docs/build-with-claude/streaming
struct AnthropicStreamEvent: Decodable {
    let type: String
    /// Block index this event applies to (`content_block_*`).
    let index: Int?
    /// Present on `message_start`.
    let message: MessageStart?
    /// Present on `content_block_start`.
    let contentBlock: ContentBlock?
    /// Present on `content_block_delta` and `message_delta` (the latter carries
    /// `stop_reason`).
    let delta: Delta?
    /// Top-level usage on `message_delta` (cumulative output tokens).
    let usage: Usage?
    /// Present on the `error` event.
    let error: ErrorBody?

    /// The opening envelope: response id, model, and the prompt token count.
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

    /// One web-search result inside a `web_search_tool_result` block.
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
