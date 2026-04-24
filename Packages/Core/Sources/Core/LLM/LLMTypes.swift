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

/// Persisted user-facing configuration for a model + endpoint + key triple.
/// `apiKeyRef` is a Keychain reference, never the API (Application
/// Programming Interface) key itself.
public struct ModelConfiguration: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let baseURL: URL
    public let apiKeyRef: String
    public let modelID: String
    public let supportsThinking: Bool
    public let maxContextTokens: Int

    public init(
        id: String,
        name: String,
        baseURL: URL,
        apiKeyRef: String,
        modelID: String,
        supportsThinking: Bool = false,
        maxContextTokens: Int = 8_192
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.modelID = modelID
        self.supportsThinking = supportsThinking
        self.maxContextTokens = maxContextTokens
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
