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
    public var toolCallId: String?
    public var createdAt: Date
    public var tokenCount: Int?

    public init(
        id: String,
        conversationId: String,
        role: MessageRole,
        content: String,
        toolCallId: String? = nil,
        createdAt: Date,
        tokenCount: Int? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.createdAt = createdAt
        self.tokenCount = tokenCount
    }
}
