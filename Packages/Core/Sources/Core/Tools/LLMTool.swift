import Foundation

/// Declarative tool description shown to the LLM (Large Language Model).
///
/// Metadata only — it tells the model what tools exist, what parameters they
/// take, and what category they fall in. Execution lives in a separate
/// `ToolExecutor` referenced by `ToolRegistration`. Splitting the two lets the
/// same tool target a local executor or a remote endpoint depending on
/// deployment.
public struct LLMTool: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// LLM-facing tool prompt: tells the model when and how to call the tool.
    /// This is system-prompt text, **not** user-facing copy — never surface it
    /// in the UI. Human-readable labels live in `displayName` / `summary`.
    public let description: String
    public let category: LLMToolCategory
    public let parameters: [LLMToolParameter]
    public let appletId: String
    /// Friendly, user-facing title (e.g. "Bible annotations"). `nil` falls back
    /// to `name`. Shown in the Tools settings list and the chat tool-call card.
    public let displayName: String?
    /// One-line, user-readable description of what the tool does. `nil` hides
    /// the subtitle. Distinct from `description`, which is the LLM prompt.
    public let summary: String?

    public init(
        id: String,
        name: String,
        description: String,
        category: LLMToolCategory,
        parameters: [LLMToolParameter],
        appletId: String,
        displayName: String? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.parameters = parameters
        self.appletId = appletId
        self.displayName = displayName
        self.summary = summary
    }
}

/// Coarse hint for the orchestrator about a tool's side-effects. Used to
/// drive auto-execute vs. confirmation policies in later milestones.
public enum LLMToolCategory: String, Sendable, Equatable, Codable, CaseIterable {
    case query
    case mutation
    case navigation
    case system
}

/// One named parameter on an `LLMTool`, with type, description, requirement,
/// and optional enum-value constraint. Mirrors a JSON Schema property.
public struct LLMToolParameter: Sendable, Equatable {
    public let name: String
    public let type: ParameterType
    public let description: String
    public let isRequired: Bool
    public let enumValues: [String]?

    public init(
        name: String,
        type: ParameterType,
        description: String,
        isRequired: Bool = false,
        enumValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.enumValues = enumValues
    }
}

/// JSON Schema-style primitive type for tool parameters. Maps onto provider
/// tool/function schemas.
public enum ParameterType: String, Sendable, Equatable, Codable, CaseIterable {
    case string
    case integer
    case number
    case bool
    case array
    case object
}
