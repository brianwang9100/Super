import Core
import Foundation

// Wire-level Codable shapes for Google's Gemini **`generateContent`** API
// (Application Programming Interface) — `POST /v1beta/models/{model}:streamGenerateContent?alt=sse`.
// Internal; every public surface stays on `GeminiNativeLLMProvider`.
//
// Gemini's shape differs from OpenAI Chat Completions in the ways this file
// encodes: there is no system *role* — the system prompt rides a top-level
// `systemInstruction`; conversation roles are `user`/`model` (not `assistant`);
// tool *results* ride a `user`-role content as a `functionResponse` part; and
// native web search is the `google_search` grounding tool whose results come
// back as `groundingMetadata` (no per-result opaque blob to echo, unlike
// Anthropic). Request/response JSON is already camelCase, so no key strategy is
// applied — property names map 1:1.

/// Gemini native web-search (grounding) tool — naming in one place.
///
/// `google_search` is the Gemini 2.x grounding tool (the 1.5-era
/// `google_search_retrieval` is not used). It carries no version string and no
/// extra capability dependency. Docs:
/// https://ai.google.dev/gemini-api/docs/google-search
enum GeminiWebSearch {
    static let toolName = "google_search"
}

// MARK: - Request

/// Request body for `POST {baseURL}/models/{model}:streamGenerateContent?alt=sse`.
/// Keys are Gemini's native camelCase, matched by the property names.
struct GeminiGenerateContentRequest: Encodable {
    let contents: [GeminiContent]
    /// System prompt. Gemini carries it here, not as a message role.
    let systemInstruction: GeminiContent?
    let generationConfig: GenerationConfig?
    let tools: [GeminiTool]?

    /// Per-request generation knobs.
    struct GenerationConfig: Encodable {
        let temperature: Double?
        /// Enables Gemini 2.5 "thinking" so the stream carries `thought` parts.
        /// ⚠️ Unverified against the live API (no network in unit tests); the
        /// shape is covered by serialization tests and flagged for PR4 live
        /// validation. Omitted entirely for non-thinking models.
        let thinkingConfig: ThinkingConfig?
    }

    /// Gemini thinking toggle. `includeThoughts` asks the model to stream its
    /// reasoning as `thought:true` parts.
    struct ThinkingConfig: Encodable {
        let includeThoughts: Bool
    }
}

/// One content turn in `contents` (or the lone `systemInstruction`). `role` is
/// `user`/`model` for conversation turns and omitted for the system
/// instruction. `GeminiNativeLLMProvider` merges adjacent same-role Core
/// messages so the user/model turns stay well-formed.
struct GeminiContent: Encodable {
    let role: String?
    let parts: [GeminiPart]

    init(role: String?, parts: [GeminiPart]) {
        self.role = role
        self.parts = parts
    }
}

/// One part inside a content turn. `text` is prose; `functionCall` replays a
/// prior assistant tool call; `functionResponse` carries a tool result. Both
/// carry an optional `id` — Gemini's per-call identity, matched result→call
/// when present (omitted for older id-less turns; `name` still rides along).
///
/// `functionCall` carries an optional `thoughtSignature` — an opaque token
/// Gemini's thinking models attach to the call and **require** echoed back on
/// the next turn's `functionCall` part (a replay that omits it is rejected
/// with HTTP 400 `INVALID_ARGUMENT`). It rides the *part*, as a sibling of the
/// `functionCall` object, not inside it.
enum GeminiPart: Encodable {
    case text(String)
    case functionCall(id: String?, name: String, args: JSONValue, thoughtSignature: String?)
    case functionResponse(id: String?, name: String, response: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case text, functionCall, functionResponse, thoughtSignature
    }

    // `id` is optional: synthesized `Encodable` uses `encodeIfPresent` for
    // Optionals, so a nil id omits the key entirely — keeping requests for
    // id-less (older) Gemini turns byte-identical to before.
    private struct FunctionCallBody: Encodable {
        let id: String?
        let name: String
        let args: JSONValue
    }

    private struct FunctionResponseBody: Encodable {
        let id: String?
        let name: String
        let response: JSONValue
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .functionCall(let id, let name, let args, let thoughtSignature):
            try container.encode(FunctionCallBody(id: id, name: name, args: args), forKey: .functionCall)
            if let thoughtSignature {
                try container.encode(thoughtSignature, forKey: .thoughtSignature)
            }
        case .functionResponse(let id, let name, let response):
            try container.encode(FunctionResponseBody(id: id, name: name, response: response), forKey: .functionResponse)
        }
    }
}

/// A tool advertised in the request. `googleSearch` is the native grounding
/// tool; `functionDeclarations` carries client tools (Gemini groups them all
/// under one tool object).
enum GeminiTool: Encodable {
    case googleSearch
    case functionDeclarations([GeminiFunctionDeclaration])

    private enum CodingKeys: String, CodingKey {
        case googleSearch = "google_search"
        case functionDeclarations
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .googleSearch:
            try container.encode(EmptyObject(), forKey: .googleSearch)
        case .functionDeclarations(let declarations):
            try container.encode(declarations, forKey: .functionDeclarations)
        }
    }

    /// `{"google_search":{}}` — the value is an empty object, not null.
    private struct EmptyObject: Encodable {}
}

/// A client tool's JSON-Schema declaration under `functionDeclarations`.
struct GeminiFunctionDeclaration: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

// MARK: - Stream

/// One decoded `streamGenerateContent` chunk. With `?alt=sse` each SSE
/// (Server-Sent Events) frame is an unnamed `data:` line carrying a partial
/// `GenerateContentResponse`; there is no `event:` name and no terminal
/// sentinel — the stream ends when the connection closes (the final chunk
/// carries `finishReason`). All fields are optional; the reducer reads only
/// what a given chunk populates. Docs:
/// https://ai.google.dev/api/generate-content
struct GeminiStreamResponse: Decodable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
    /// The resolved model version, captured for `.messageStart`.
    let modelVersion: String?
    /// Stable response id when present (newer API versions), else nil.
    let responseId: String?
    /// Present when a frame carries a streamed error envelope rather than a
    /// candidate (most Gemini failures arrive as a non-2xx HTTP status handled
    /// by the transport path, but a mid-stream error can land here).
    let error: ErrorBody?

    struct ErrorBody: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
        let groundingMetadata: GroundingMetadata?
    }

    struct Content: Decodable {
        let role: String?
        let parts: [Part]?
    }

    /// One streamed part. `thought == true` marks a reasoning fragment;
    /// `functionCall` is a client tool call (delivered whole, not streamed).
    /// `thoughtSignature` is the opaque token a thinking model attaches to a
    /// `functionCall`; it must be echoed back verbatim on the next turn (see
    /// `GeminiPart`), so the reducer surfaces it on the `.toolUse` event.
    struct Part: Decodable {
        let text: String?
        let thought: Bool?
        let functionCall: FunctionCall?
        let thoughtSignature: String?
    }

    struct FunctionCall: Decodable {
        /// Gemini's unique per-call id. Present on parallel/multi-tool turns
        /// (e.g. `gemini-3.5-flash`); absent on older single-call paths. When
        /// present it is the call's identity and must be round-tripped on the
        /// `functionResponse` so results match calls — using the function name
        /// as the id instead collapses parallel same-tool calls onto one id.
        let id: String?
        let name: String?
        let args: JSONValue?
    }

    /// Native-search attribution. `webSearchQueries` drives `.searchStarted`;
    /// `groundingChunks` + `groundingSupports` become `SourceCitation`s;
    /// `searchEntryPoint.renderedContent` is the mandatory Google Search
    /// Suggestions HTML.
    struct GroundingMetadata: Decodable {
        let webSearchQueries: [String]?
        let groundingChunks: [GroundingChunk]?
        let groundingSupports: [GroundingSupport]?
        let searchEntryPoint: SearchEntryPoint?
    }

    struct GroundingChunk: Decodable {
        let web: WebChunk?

        struct WebChunk: Decodable {
            let uri: String?
            let title: String?
        }
    }

    struct GroundingSupport: Decodable {
        let segment: Segment?
        let groundingChunkIndices: [Int]?

        struct Segment: Decodable {
            let startIndex: Int?
            let endIndex: Int?
            let text: String?
        }
    }

    struct SearchEntryPoint: Decodable {
        let renderedContent: String?
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        /// Implicit-cache hit count (a *subset* already counted in
        /// `promptTokenCount`). Present on Gemini 2.5+/3.x when a cache hit
        /// occurs; absent otherwise.
        let cachedContentTokenCount: Int?
    }
}
