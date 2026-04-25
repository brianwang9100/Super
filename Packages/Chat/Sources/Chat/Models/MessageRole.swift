import Core
import Foundation

/// Author of a stored `MessageRecord` row.
///
/// Owned by Chat (not Core) so the on-disk schema is decoupled from
/// `Core.LLMRole`'s evolution: a future LLM (Large Language Model) provider
/// case or a Chat-only row kind (e.g. a future compaction summary)
/// shouldn't force a database migration. The case set happens to match
/// `LLMRole` today; the separate type is the boundary where any future
/// divergence becomes an explicit decision in `asLLMRole()` rather than
/// silent drift.
public enum MessageRole: String, Sendable, Equatable, Codable, CaseIterable {
    case user
    case assistant
    case system
    case tool
}

extension MessageRole {
    /// Translate to Core's `LLMRole` for handing the record to a provider.
    public func asLLMRole() -> LLMRole {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        case .tool: return .tool
        }
    }

    /// Build a `MessageRole` from a provider-side `LLMRole`. The reverse
    /// of `asLLMRole()`; total over both enums.
    public init(_ llmRole: LLMRole) {
        switch llmRole {
        case .user: self = .user
        case .assistant: self = .assistant
        case .system: self = .system
        case .tool: self = .tool
        }
    }
}
