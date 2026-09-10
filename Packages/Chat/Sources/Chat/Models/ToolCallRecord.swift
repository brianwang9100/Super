import Core
import Foundation
import GRDB

public enum ToolCallStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case executing
    case success
    case failed
    case cancelled
    case awaitingConfirmation
}

/// id preserves provider call IDs or uses a marked local ID for id-less calls.
/// Parameters/results are JSON strings to keep column coding flat.
/// conversationId is denormalized for queries without a message join.
public struct ToolCallRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "toolCall"

    /// Marks synthetic IDs so Gemini can omit them on replay. Other strict providers
    /// accept the marked unique string as their required call ID.
    public static let locallyMintedIDPrefix = "localtoolu_"

    public static func locallyMintedID(_ raw: String) -> String { locallyMintedIDPrefix + raw }

    public static func isLocallyMintedID(_ id: String) -> Bool { id.hasPrefix(locallyMintedIDPrefix) }

    public var id: String
    public var messageId: String
    public var conversationId: String
    public var toolName: String
    public var parameters: String
    public var result: String?
    public var status: ToolCallStatus
    public var createdAt: Date
    public var completedAt: Date?
    /// Opaque continuation signature; Gemini rejects tool replay without it.
    public var signature: String?

    public init(
        id: String,
        messageId: String,
        conversationId: String,
        toolName: String,
        parameters: String,
        result: String? = nil,
        status: ToolCallStatus,
        createdAt: Date,
        completedAt: Date? = nil,
        signature: String? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.conversationId = conversationId
        self.toolName = toolName
        self.parameters = parameters
        self.result = result
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.signature = signature
    }
}

extension ToolCallRecord {
    public func decodedParameters() throws -> JSONValue {
        try decode(parameters)
    }

    public func decodedResult() throws -> JSONValue? {
        guard let result else { return nil }
        return try decode(result)
    }

    public static func encode(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToolCallCodecError.invalidUTF8
        }
        return string
    }

    private func decode(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }
}

public enum ToolCallCodecError: Error, Sendable, Equatable {
    case invalidUTF8
}
