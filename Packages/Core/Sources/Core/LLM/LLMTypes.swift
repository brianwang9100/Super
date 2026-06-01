import Foundation

/// Author of a chat message. Mirrors the OpenAI/Anthropic role taxonomy plus
/// `tool` for tool-result messages sent back to the model.
public enum LLMRole: String, Sendable, Equatable, Codable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}

/// One block within a message. A single `LLMMessage` may carry multiple
/// blocks — e.g. an assistant response with both text and a tool-use call.
public enum LLMContent: Sendable, Equatable {
    case text(String)
    /// Tool invocation requested by the model. `input` is conventionally a
    /// `JSONValue.object` matching the tool's parameter schema; the type is
    /// a single `JSONValue` (rather than `[String: JSONValue]`) so the
    /// payload encodes/decodes through `Codable` in one hop.
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
}

/// One message in a chat with an LLM (Large Language Model). Always carries
/// at least one content block; the convenience text initializer wraps a
/// single string in a `.text` block.
public struct LLMMessage: Sendable, Equatable {
    public let role: LLMRole
    public let content: [LLMContent]

    public init(role: LLMRole, content: [LLMContent]) {
        self.role = role
        self.content = content
    }

    /// Convenience initializer for the common single-text-block case.
    public init(role: LLMRole, text: String) {
        self.init(role: role, content: [.text(text)])
    }
}

/// Identifies a model exposed by an LLM provider. `id` is the provider-side
/// identifier sent on the wire (e.g. `"gpt-4o-mini"`); `displayName` is what
/// the user sees in the model picker.
public struct LLMModel: Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let supportsThinking: Bool
    public let supportsTools: Bool
    public let maxContextTokens: Int

    public init(
        id: String,
        displayName: String,
        supportsThinking: Bool = false,
        supportsTools: Bool = true,
        maxContextTokens: Int = 8_192
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsThinking = supportsThinking
        self.supportsTools = supportsTools
        self.maxContextTokens = maxContextTokens
    }
}

/// Wire-protocol family of an LLM provider. Discriminates which provider
/// class (and which fields on `ModelConfiguration`) a configuration row
/// projects through. Persisted as the row's `kind` column.
///
/// This is *not* a brand identifier — Gemini, OpenAI, DeepSeek, Groq, MLX,
/// and Ollama all speak the OpenAI Chat Completions wire format and thus
/// share `.openAICompatible`. New cases are added when a genuinely new wire
/// format needs its own provider class (e.g. a native Anthropic Messages
/// API provider, or a native Gemini provider).
public enum LLMProviderKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// On-device model via Apple's `FoundationModels` framework. No
    /// `baseURL` or `apiKeyRef`; the row's `modelID` selects which
    /// system model variant to use.
    case appleFoundation
    /// Any HTTP endpoint speaking the OpenAI Chat Completions wire format
    /// (hosted OpenAI, Gemini's `v1beta/openai/` shim, DeepSeek, Together,
    /// Groq, Ollama, MLX, LM Studio, llama.cpp). Requires `baseURL` and
    /// optionally `apiKeyRef`.
    case openAICompatible
    /// Native Anthropic Messages API (`/v1/messages`) adapter. Selected at
    /// add-time when a model opts into native web search; the OpenAI-compat
    /// shim can't carry Anthropic's `web_search` server tool or citations.
    /// The adapter itself lands in a later PR — see the native-web-search
    /// design spec.
    case anthropicNative
    /// Native Gemini `generateContent` adapter (`google_search` grounding).
    /// Distinct from the `.openAICompatible` Google shim. Adapter lands in
    /// a later PR.
    case geminiNative
    /// Native OpenAI Responses API (`/v1/responses`) adapter (`web_search`
    /// tool + `url_citation` annotations). Distinct from the
    /// `.openAICompatible` Chat Completions path. Implemented by
    /// `OpenAIResponsesLLMProvider` (web-search PR3a).
    case openAIResponses
    #if DEBUG
    /// Development-only fake provider that streams canned markdown
    /// responses with randomized delays. Used to exercise the streaming
    /// UI path (scroll behavior, thinking blocks, code-block rendering)
    /// without depending on a real LLM endpoint. Gated entirely under
    /// `#if DEBUG` — neither the enum case, the provider class, nor the
    /// seed/registration call sites compile into Release builds.
    case debug
    #endif

    /// Whether the running binary can construct a live `LLMProvider` for
    /// this kind. `true` for kinds with a shipped adapter
    /// (`.openAICompatible`, `.appleFoundation`, `.openAIResponses`, and
    /// `.debug` in DEBUG); **`false` for the native-search kinds whose
    /// adapters haven't shipped yet** (`.anthropicNative`, `.geminiNative`) —
    /// the catalog already advertises `nativeSearchAdapter`, and a row can
    /// carry a native `kind` before the adapter exists, so callers gate on
    /// this rather than assuming every persisted kind is buildable.
    ///
    /// Distinct from "is this kind decodable in this binary" (which the
    /// repository's `knownKindRequest` covers): a not-yet-built native kind
    /// decodes fine but has no provider to register, so a row carrying it
    /// must not claim the active-provider slot (`selected()`), must not
    /// trigger an unregister-without-re-register on edit, and must not be
    /// classified by URL in the edit pane. Flip the relevant arm to `true`
    /// in the PR that lands that adapter — `.openAIResponses` flipped when
    /// `OpenAIResponsesLLMProvider` shipped (web-search PR3a).
    public var hasProviderAdapter: Bool {
        switch self {
        case .openAICompatible, .appleFoundation, .openAIResponses:
            return true
        case .anthropicNative, .geminiNative:
            return false
        #if DEBUG
        case .debug:
            return true
        #endif
        }
    }
}

/// Persisted user-facing configuration for a model + endpoint + key triple.
/// `apiKeyRef` is a Keychain reference, never the API (Application
/// Programming Interface) key itself.
///
/// `baseURL` and `apiKeyRef` are optional because on-device kinds like
/// `.appleFoundation` have neither — they're invariantly nil for those
/// rows. For `.openAICompatible` rows `baseURL` is required (callers
/// preconditionFailure on nil); `apiKeyRef` may be nil for local
/// servers that don't require auth.
public struct ModelConfiguration: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: LLMProviderKind
    public let name: String
    public let baseURL: URL?
    public let apiKeyRef: String?
    public let modelID: String
    public let supportsThinking: Bool
    public let maxContextTokens: Int
    /// Selected web-search engine for this model: `"native"` (the
    /// provider's own server-side search, requires a native `kind`), a
    /// standalone search-provider id, or `nil` for no web search. Drives
    /// provider hydration and the per-turn tool wiring in later PRs.
    public let searchBackend: String?

    public init(
        id: String,
        kind: LLMProviderKind,
        name: String,
        baseURL: URL?,
        apiKeyRef: String?,
        modelID: String,
        supportsThinking: Bool = false,
        maxContextTokens: Int = 8_192,
        searchBackend: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.modelID = modelID
        self.supportsThinking = supportsThinking
        self.maxContextTokens = maxContextTokens
        self.searchBackend = searchBackend
    }
}

/// Token counts reported by the provider at end of stream. Drives both the
/// context meter UI and any future accounting.
public struct TokenUsage: Sendable, Equatable, Codable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var total: Int { inputTokens + outputTokens }
}

/// Normalized error type so all providers surface the same cases.
/// Wire-level error payloads map to `.providerError(code:message:)`.
public enum LLMError: Error, Sendable, Equatable {
    case unauthorized
    case rateLimited
    case unsupportedModel(String)
    case providerError(code: String, message: String)
    case decodingFailed(String)
    case requestFailed(String)
    case cancelled
}
