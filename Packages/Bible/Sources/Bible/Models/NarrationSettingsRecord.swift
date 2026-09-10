import Foundation
import GRDB

public struct NarrationSettingsRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "narrationSettings"
    public var id: String
    public var scope = "narration"
    public var enabled: Bool?
    public var sourceId: String?
    public var sourceName: String?
    public var keyRef: String?
    public var ownsKey = false
    public var preferredVoiceId: String?
    public var lastAppleVoiceId: String?
    public var rate: Double = 1
    public var prefetchVerseCount = 2
    public var revision = 0
    public var retiredKeyRefs: [String] = []
    public var updatedAt: Date
    public init(id: String, updatedAt: Date) {
        self.id = id
        self.updatedAt = updatedAt
    }
}
