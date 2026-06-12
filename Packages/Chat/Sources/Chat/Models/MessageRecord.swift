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
    /// Provider integrity signature for this turn's thinking block
    /// (Anthropic `signature_delta`). Required to replay the block verbatim
    /// on the next tool-loop request — the Messages API 400s a rebuilt
    /// last-assistant turn without it. Nil for non-thinking turns, for
    /// providers that don't sign, for rows persisted before v8, and for
    /// turns containing `redacted_thinking` (not replayable).
    public var thinkingSignature: String?
    public var toolCallId: String?
    public var createdAt: Date
    public var tokenCount: Int?
    /// JSON-encoded ``MessageAttachments``, or nil when the message
    /// carries no structured attachments. Stored as a raw string so
    /// `MessageRecord` stays a flat `Codable`/`PersistableRecord` with no
    /// custom column coding; read it back through ``attachments``.
    public var attachmentsJSON: String?

    public init(
        id: String,
        conversationId: String,
        role: MessageRole,
        content: String,
        thinkingContent: String? = nil,
        thinkingDurationMs: Int? = nil,
        thinkingSignature: String? = nil,
        toolCallId: String? = nil,
        createdAt: Date,
        tokenCount: Int? = nil,
        attachmentsJSON: String? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.thinkingContent = thinkingContent
        self.thinkingDurationMs = thinkingDurationMs
        self.thinkingSignature = thinkingSignature
        self.toolCallId = toolCallId
        self.createdAt = createdAt
        self.tokenCount = tokenCount
        self.attachmentsJSON = attachmentsJSON
    }

    /// Decoded structured attachments, or nil when `attachmentsJSON` is
    /// absent or fails to decode.
    public var attachments: MessageAttachments? {
        guard let attachmentsJSON, let data = attachmentsJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(MessageAttachments.self, from: data)
    }

    /// Encode `attachments` to the raw column string. Returns nil when
    /// there is nothing worth persisting, so the column stays NULL rather
    /// than holding an empty payload.
    public static func encode(_ attachments: MessageAttachments) -> String? {
        guard !attachments.isEmpty, let data = try? JSONEncoder().encode(attachments) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
