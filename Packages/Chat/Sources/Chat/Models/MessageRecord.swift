import Foundation
import GRDB

/// One row in a conversation's message log. `role` is Chat's `MessageRole`
/// (owned by Chat so the schema doesn't track Core's `LLMRole`); call
/// `role.asLLMRole()` when handing the row to a provider. `tool` rows
/// (rows carrying the result of a tool invocation) populate `toolCallId`
/// with the originating `ToolCallRecord.id`; every other role leaves it
/// nil.
public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "message"

    public var id: String
    public var conversationId: String
    public var role: MessageRole
    public var content: String
    /// Reasoning trace emitted by the model alongside `content`, when the
    /// provider exposes one (OpenAI's `reasoning` / `reasoning_content`,
    /// Anthropic's thinking blocks, etc.). Stored verbatim so the UI can
    /// re-render the same trace it showed live; nil for non-thinking
    /// turns and for non-assistant rows.
    public var thinkingContent: String?
    /// Wall-clock duration (milliseconds) between the first and last
    /// thinking delta of this turn. Drives the "Thought for Xs" label;
    /// nil when `thinkingContent` is nil.
    public var thinkingDurationMs: Int?
    public var toolCallId: String?
    public var createdAt: Date
    public var tokenCount: Int?

    public init(
        id: String,
        conversationId: String,
        role: MessageRole,
        content: String,
        thinkingContent: String? = nil,
        thinkingDurationMs: Int? = nil,
        toolCallId: String? = nil,
        createdAt: Date,
        tokenCount: Int? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.thinkingContent = thinkingContent
        self.thinkingDurationMs = thinkingDurationMs
        self.toolCallId = toolCallId
        self.createdAt = createdAt
        self.tokenCount = tokenCount
    }
}
