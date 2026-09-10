import Foundation

/// Metadata only; ToolRegistration supplies the executor.
public struct LLMTool: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// LLM prompt, never UI copy; use displayName/summary for people.
    public let description: String
    public let category: LLMToolCategory
    public let parameters: [LLMToolParameter]
    public let appletId: String
    /// Nil falls back to name.
    public let displayName: String?
    /// Nil hides the UI subtitle; description remains LLM-only.
    public let summary: String?
    /// Compact-context prompt; nil falls back to description. Never display as UI copy.
    public let compactDescription: String?

    public init(
        id: String,
        name: String,
        description: String,
        category: LLMToolCategory,
        parameters: [LLMToolParameter],
        appletId: String,
        displayName: String? = nil,
        summary: String? = nil,
        compactDescription: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.parameters = parameters
        self.appletId = appletId
        self.displayName = displayName
        self.summary = summary
        self.compactDescription = compactDescription
    }
}

/// Coarse side-effect hint used by execution policy.
public enum LLMToolCategory: String, Sendable, Equatable, Codable, CaseIterable {
    case query
    case mutation
    case navigation
    case system
}

public struct LLMToolParameter: Sendable, Equatable {
    public let name: String
    public let type: ParameterType
    public let description: String
    public let isRequired: Bool
    public let enumValues: [String]?
    /// Element/nested schema for arrays/objects; nil for scalars. Gemini rejects arrays without items.
    public let valueSchema: ToolValueSchema?
    /// Compact-context parameter prompt; nil falls back to description. Never UI copy.
    public let compactDescription: String?

    public init(
        name: String,
        type: ParameterType,
        description: String,
        isRequired: Bool = false,
        enumValues: [String]? = nil,
        valueSchema: ToolValueSchema? = nil,
        compactDescription: String? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.enumValues = enumValues
        self.valueSchema = valueSchema
        self.compactDescription = compactDescription
    }
}

public indirect enum ToolValueSchema: Sendable, Equatable {
    case scalar(ParameterType, enumValues: [String]? = nil)
    /// Property isRequired flags determine the nested required list.
    case object([LLMToolParameter])
    case array(element: ToolValueSchema)
}

public enum ParameterType: String, Sendable, Equatable, Codable, CaseIterable {
    case string
    case integer
    case number
    case bool
    case array
    case object
}
