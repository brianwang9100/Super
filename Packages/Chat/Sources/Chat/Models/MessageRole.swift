import Core
import Foundation

/// Chat owns persisted role values so Core role changes cannot silently alter the schema.
public enum MessageRole: String, Sendable, Equatable, Codable, CaseIterable {
    case user
    case assistant
    case system
    case tool
}

extension MessageRole {
    public func asLLMRole() -> LLMRole {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        case .tool: return .tool
        }
    }

    public init(_ llmRole: LLMRole) {
        switch llmRole {
        case .user: self = .user
        case .assistant: self = .assistant
        case .system: self = .system
        case .tool: self = .tool
        }
    }
}
