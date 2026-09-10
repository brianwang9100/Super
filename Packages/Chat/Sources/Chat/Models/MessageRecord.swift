import Foundation
import GRDB

public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "message"

    public var id: String
    public var conversationId: String
    public var role: MessageRole
    public var content: String
    /// Verbatim reasoning trace, retained after the streaming tail clears.
    public var thinkingContent: String?
    /// Milliseconds from first to last thinking delta; nil for turns without thinking.
    public var thinkingDurationMs: Int?
    /// Opaque thinking signature required for replay; absent for legacy, unsigned, or redacted turns.
    public var thinkingSignature: String?
    /// Originating model ID; replay thinking signatures only to the same model.
    public var thinkingModelId: String?
    public var toolCallId: String?
    public var createdAt: Date
    public var tokenCount: Int?
    /// Raw JSON keeps GRDB column coding flat; read through attachments.
    public var attachmentsJSON: String?

    public init(
        id: String,
        conversationId: String,
        role: MessageRole,
        content: String,
        thinkingContent: String? = nil,
        thinkingDurationMs: Int? = nil,
        thinkingSignature: String? = nil,
        thinkingModelId: String? = nil,
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
        self.thinkingModelId = thinkingModelId
        self.toolCallId = toolCallId
        self.createdAt = createdAt
        self.tokenCount = tokenCount
        self.attachmentsJSON = attachmentsJSON
    }

    public var attachments: MessageAttachments? {
        guard let attachmentsJSON, let data = attachmentsJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(MessageAttachments.self, from: data)
    }

    /// Returns nil for empty or unencodable attachments so the column stays NULL.
    public static func encode(_ attachments: MessageAttachments) -> String? {
        guard !attachments.isEmpty, let data = try? JSONEncoder().encode(attachments) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
