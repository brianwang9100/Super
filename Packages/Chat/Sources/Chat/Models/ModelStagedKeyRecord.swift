import GRDB

/// Durable cleanup ownership for a provisional or retired model key, containing only its opaque Keychain reference.
public struct ModelStagedKeyRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    /// SQLite ledger in the existing Chat database.
    public static let databaseTableName = "modelStagedKey"
    /// An opaque Keychain reference, never the secret itself.
    public var id: String
    /// Creates cleanup metadata for a generated or retired reference.
    public init(id: String) { self.id = id }
}
