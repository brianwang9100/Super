import GRDB

/// Durable cleanup ownership for a provisional narration key; its ID is an opaque Keychain reference, never a secret.
public struct NarrationStagedKeyRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "narrationStagedKey"
    public var id: String
    public init(id: String) { self.id = id }
}
