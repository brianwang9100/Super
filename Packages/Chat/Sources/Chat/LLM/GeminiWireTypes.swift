import Core
import Foundation

/// Uses Gemini 2.x `google_search` grounding.
enum GeminiWebSearch {
    static let toolName = "google_search"
}

// MARK: - Request

struct GeminiGenerateContentRequest: Encodable {
    let contents: [GeminiContent]
    /// System prompt. Gemini carries it here, not as a message role.
    let systemInstruction: GeminiContent?
    let generationConfig: GenerationConfig?
    let tools: [GeminiTool]?

    struct GenerationConfig: Encodable {
        let temperature: Double?
        /// Omitted for models without thinking support.
        let thinkingConfig: ThinkingConfig?
    }

    struct ThinkingConfig: Encodable {
        let includeThoughts: Bool
    }
}

/// Conversation roles alternate `user`/`model`; system instructions omit a role.
struct GeminiContent: Encodable {
    let role: String?
    let parts: [GeminiPart]

    init(role: String?, parts: [GeminiPart]) {
        self.role = role
        self.parts = parts
    }
}

/// Call IDs correlate parallel results; thought signatures ride the part and must replay verbatim.
enum GeminiPart: Encodable {
    case text(String)
    case functionCall(id: String?, name: String, args: JSONValue, thoughtSignature: String?)
    case functionResponse(id: String?, name: String, response: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case text, functionCall, functionResponse, thoughtSignature
    }

    // Omit IDs for legacy id-less turns.
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

struct GeminiFunctionDeclaration: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

// MARK: - Stream

/// Unnamed SSE chunk; connection close terminates the stream.
struct GeminiStreamResponse: Decodable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
    let modelVersion: String?
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

    /// Tool-call thought signatures must be surfaced for verbatim replay.
    struct Part: Decodable {
        let text: String?
        let thought: Bool?
        let functionCall: FunctionCall?
        let thoughtSignature: String?
    }

    struct FunctionCall: Decodable {
        /// Must round-trip when present so parallel calls to one function remain distinct.
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
