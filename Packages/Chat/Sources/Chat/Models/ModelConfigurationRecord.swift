import Core
import Foundation
import GRDB

/// apiKeyRef names a Keychain entry, never plaintext. On-device kinds need no URL
/// or key; network providers require a URL but may allow unauthenticated local servers.
/// A partial unique index permits at most one selected row.
public struct ModelConfigurationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "modelConfiguration"

    public var id: String
    public var kind: LLMProviderKind
    public var name: String
    public var baseURL: URL?
    public var apiKeyRef: String?
    public var modelId: String
    public var supportsThinking: Bool
    public var maxContextTokens: Int
    public var isSelected: Bool
    public var createdAt: Date
    /// Provider identity is explicit; compatible protocol kinds do not imply a company.
    public var providerId: String?
    /// native selects server search; debug selects mock search; other IDs name standalone backends.
    /// The picker establishes native kind/URL pairing; this record does not enforce it.
    public var searchBackend: String?

    public init(
        id: String,
        name: String,
        baseURL: URL?,
        apiKeyRef: String?,
        modelId: String,
        createdAt: Date,
        kind: LLMProviderKind = .openAICompatible,
        supportsThinking: Bool = false,
        maxContextTokens: Int = 8_192,
        isSelected: Bool = false,
        searchBackend: String? = nil,
        providerId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.modelId = modelId
        self.supportsThinking = supportsThinking
        self.maxContextTokens = maxContextTokens
        self.isSelected = isSelected
        self.createdAt = createdAt
        self.searchBackend = searchBackend
        self.providerId = providerId
    }

    public var configuration: ModelConfiguration {
        ModelConfiguration(
            id: id,
            kind: kind,
            name: name,
            baseURL: baseURL,
            apiKeyRef: apiKeyRef,
            modelID: modelId,
            supportsThinking: supportsThinking,
            maxContextTokens: maxContextTokens,
            searchBackend: searchBackend
        )
    }
}
