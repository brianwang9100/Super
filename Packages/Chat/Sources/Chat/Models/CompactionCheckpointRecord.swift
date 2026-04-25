import Foundation
import GRDB

/// Summary of older messages produced when a conversation approaches its
/// model's context window. The "live" checkpoint is the one currently
/// substituted for the messages it covers; older checkpoints are kept
/// (`isLive == false`) for audit and potential roll-back.
///
/// `uptoMessageId` is the inclusive upper bound: every message at or
/// before that row is represented by `summary`. `tokensBefore`/`tokensAfter`
/// are diagnostics — how many tokens the summarized window held vs. the
/// summary that replaced it.
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
