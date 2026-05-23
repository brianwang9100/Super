import Core
import Foundation
import GRDB

/// User-configured LLM (Large Language Model) endpoint + model triple.
///
/// `apiKeyRef` is a Keychain reference (typically a UUID), never the raw
/// key — see `ModelConfigurationRepository` for the Keychain wiring. The
/// "at most one selected row" invariant is enforced by a partial unique
/// index on `(isSelected) WHERE isSelected = 1`, so any second selected
/// row throws a UNIQUE constraint violation at insert time.
///
/// `baseURL` and `apiKeyRef` are nullable because on-device kinds like
/// `.appleFoundation` have neither. For `.openAICompatible` rows `baseURL`
/// is required by the OpenAI-compatible provider; `apiKeyRef` may be nil
/// for local servers that don't require auth.
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
        isSelected: Bool = false
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
    }

    /// Project this row to the Core `ModelConfiguration` value used by
    /// `LLMProvider` consumers. Core's field is `modelID` (uppercase) —
    /// Chat uses `modelId` to stay consistent with the package's other
    /// foreign-key columns.
    public var configuration: ModelConfiguration {
        ModelConfiguration(
            id: id,
            kind: kind,
            name: name,
            baseURL: baseURL,
            apiKeyRef: apiKeyRef,
            modelID: modelId,
            supportsThinking: supportsThinking,
            maxContextTokens: maxContextTokens
        )
    }
}
