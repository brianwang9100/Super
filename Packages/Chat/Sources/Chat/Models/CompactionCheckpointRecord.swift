import Foundation
import GRDB

/// uptoMessageId is inclusive. Token counts describe the summarized window
/// before compaction and its replacement summary.
public struct CompactionCheckpointRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "compactionCheckpoint"

    public var id: String
    public var conversationId: String
    public var uptoMessageId: String
    public var summary: String
    public var tokensBefore: Int
    public var tokensAfter: Int
    public var createdAt: Date
    public var isLive: Bool

    public init(
        id: String,
        conversationId: String,
        uptoMessageId: String,
        summary: String,
        tokensBefore: Int,
        tokensAfter: Int,
        createdAt: Date,
        isLive: Bool = true
    ) {
        self.id = id
        self.conversationId = conversationId
        self.uptoMessageId = uptoMessageId
        self.summary = summary
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.createdAt = createdAt
        self.isLive = isLive
    }
}
