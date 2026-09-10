import GRDB

/// Durable cleanup ownership for a provisional or retired model key, containing only its opaque Keychain reference.
public struct ModelStagedKeyRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "modelStagedKey"
    public var id: String
    public init(id: String) { self.id = id }
}
