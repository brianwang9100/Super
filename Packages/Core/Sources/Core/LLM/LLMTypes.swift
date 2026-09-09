import Foundation

public enum LLMRole: String, Sendable, Equatable, Codable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}

public enum LLMContent: Sendable, Equatable {
    case text(String)
    /// Anthropic tool-loop replay requires original thinking content and signature.
        /// Nil signature makes replay impossible; its adapter skips the block and
        /// disables thinking for that request. Other adapters ignore unsupported blocks.
    case thinking(content: String, signature: String?)
    /// Object input matches the tool schema. Echo signature unchanged for Gemini
        /// continuation; its thinking calls reject missing signatures.
    case toolUse(id: String, name: String, input: JSONValue, signature: String?)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    /// Opaque prior search results preserve Anthropic citation validity across turns.
        /// Other adapters ignore unsupported blocks.
    case searchResult([SourceCitation])
}

/// Non-persisted cache hint: stablePrefix marks the contiguous leading briefing
/// run where an adapter may end a cache segment. Changing context/history is volatile.
/// Only the Anthropic adapter currently consumes the hint.
public enum LLMCacheHint: Sendable, Equatable {
    case stablePrefix
    case volatile
}

public struct LLMMessage: Sendable, Equatable {
    public let role: LLMRole
    public let content: [LLMContent]
    public let cacheHint: LLMCacheHint

    public init(role: LLMRole, content: [LLMContent], cacheHint: LLMCacheHint = .volatile) {
        self.role = role
        self.content = content
        self.cacheHint = cacheHint
    }

    public init(role: LLMRole, text: String, cacheHint: LLMCacheHint = .volatile) {
        self.init(role: role, content: [.text(text)], cacheHint: cacheHint)
    }
}

/// id is the upstream wire identifier, separate from the configured provider ID.
public struct LLMModel: Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let supportsThinking: Bool
    public let supportsTools: Bool
    public let maxContextTokens: Int
    /// Selected search backend: native, a standalone provider ID, or nil for none.
    public let searchBackend: String?

    public init(
        id: String,
        displayName: String,
        supportsThinking: Bool = false,
        supportsTools: Bool = true,
        maxContextTokens: Int = 8_192,
        searchBackend: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsThinking = supportsThinking
        self.supportsTools = supportsTools
        self.maxContextTokens = maxContextTokens
        self.searchBackend = searchBackend
    }
}

/// Persisted wire-protocol family, independent of the provider's brand.
public enum LLMProviderKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// On-device: no endpoint or key reference.
    case appleFoundation
    /// Chat Completions-compatible endpoint; requires baseURL and optionally a key reference.
    case openAICompatible
    case anthropicNative
    case geminiNative
    case openAIResponses
    #if DEBUG
    case debug
    #endif

    /// Adapter availability is separate from decodability for newly introduced kinds.
    public var hasProviderAdapter: Bool {
        switch self {
        case .openAICompatible, .appleFoundation, .openAIResponses, .anthropicNative, .geminiNative:
            return true
        #if DEBUG
        case .debug:
            return true
        #endif
        }
    }
}

/// apiKeyRef is a Keychain reference, never a secret. On-device rows have no
/// endpoint/key; compatible HTTP rows require baseURL but may omit authentication.
public struct ModelConfiguration: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: LLMProviderKind
    public let name: String
    public let baseURL: URL?
    public let apiKeyRef: String?
    public let modelID: String
    public let supportsThinking: Bool
    public let maxContextTokens: Int
    /// native requires a native provider kind; nil disables search.
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

/// Cache accounting differs by adapter: Anthropic cache counts are additional to
/// inputTokens; OpenAI/xAI/Gemini cache reads are already included. Other adapters
/// have no separate creation count. Nil cache fields mean no reported value.
public struct TokenUsage: Sendable, Equatable, Codable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadInputTokens: Int?
    public let cacheCreationInputTokens: Int?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    // TODO(PR2): add provider-aware billedTotal and audit context-meter/compaction callers.
        /// Input plus output; undercounts Anthropic prompt size when cache counts are present.
    public var total: Int { inputTokens + outputTokens }
}

public enum LLMError: Error, Sendable, Equatable {
    case unauthorized
    case rateLimited
    case unsupportedModel(String)
    case providerError(code: String, message: String)
    case decodingFailed(String)
    case requestFailed(String)
    case cancelled
}
