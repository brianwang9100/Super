import Core
import Foundation

/// Stable export schema; bump `currentFormatVersion` for breaking changes.
public struct ChatArchive: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date
    public let conversations: [Conversation]

    public init(exportedAt: Date, conversations: [Conversation]) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.conversations = conversations
    }

    public struct Conversation: Codable, Sendable, Equatable {
        public let id: String
        public let title: String?
        public let createdAt: Date
        public let updatedAt: Date
        public let messages: [Message]

        public init(
            id: String,
            title: String?,
            createdAt: Date,
            updatedAt: Date,
            messages: [Message]
        ) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.messages = messages
        }
    }

    public struct Message: Codable, Sendable, Equatable {
        public let id: String
        /// Uses MessageRole raw values without coupling the archive schema to that enum.
        public let role: String
        public let content: String
        public let thinkingContent: String?
        public let createdAt: Date
        public let toolCalls: [ToolCall]

        public init(
            id: String,
            role: String,
            content: String,
            thinkingContent: String?,
            createdAt: Date,
            toolCalls: [ToolCall]
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.thinkingContent = thinkingContent
            self.createdAt = createdAt
            self.toolCalls = toolCalls
        }
    }

    /// Parameters and results are nested JSON, decoded from database string columns.
    public struct ToolCall: Codable, Sendable, Equatable {
        public let id: String
        public let toolName: String
        public let parameters: JSONValue
        public let result: JSONValue?
        public let status: String
        public let createdAt: Date
        public let completedAt: Date?

        public init(
            id: String,
            toolName: String,
            parameters: JSONValue,
            result: JSONValue?,
            status: String,
            createdAt: Date,
            completedAt: Date?
        ) {
            self.id = id
            self.toolName = toolName
            self.parameters = parameters
            self.result = result
            self.status = status
            self.createdAt = createdAt
            self.completedAt = completedAt
        }
    }

    /// Canonical export uses sorted keys, pretty printing, and ISO-8601 dates.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(self)
        } catch {
            throw ChatExportError.encodingFailed
        }
    }
}

public enum ChatExportError: Error, Sendable, Equatable {
    case encodingFailed
    case fileWriteFailed
}
