import Core
import Foundation

/// Versioned, on-disk shape of a "chats only" data export.
///
/// Deliberately decoupled from the GRDB record types so the JSON
/// (JavaScript Object Notation) file format can evolve independently of the
/// database schema. `formatVersion` is the anchor a future importer or sync
/// engine keys off — bump it whenever the shape changes in a
/// non-backward-compatible way.
public struct ChatArchive: Codable, Sendable, Equatable {
    /// Current archive format. Increment on any breaking shape change.
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date
    public let conversations: [Conversation]

    public init(exportedAt: Date, conversations: [Conversation]) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.conversations = conversations
    }

    /// One exported conversation with its full message log.
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

    /// One message in a conversation, with any tool calls it triggered.
    public struct Message: Codable, Sendable, Equatable {
        public let id: String
        /// `MessageRole.rawValue` — stored as a string so the archive does
        /// not pin to Chat's internal enum.
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

    /// One tool invocation. `parameters`/`result` are real nested JSON
    /// (decoded from the DB's string columns) so the archive reads cleanly
    /// rather than carrying escaped JSON-in-a-string.
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

    /// Encode to the canonical export bytes: pretty-printed, sorted keys,
    /// ISO-8601 dates. Sorted keys keep the output byte-stable so a snapshot
    /// or golden test can assert on it.
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

/// Errors surfaced by the chat-export pipeline.
public enum ChatExportError: Error, Sendable, Equatable {
    /// `JSONEncoder` failed to serialize the archive.
    case encodingFailed
    /// The encoded archive could not be written to the temporary file.
    case fileWriteFailed
}
