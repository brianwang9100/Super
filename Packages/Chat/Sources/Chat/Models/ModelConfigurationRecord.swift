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
    /// Selected web-search engine: `"native"` (provider's own server-side
    /// search, paired with a native `kind`), `"debug"` (the DEBUG client-side
    /// mock backend — canned results via `DebugWebSearchFulfiller`, works on
    /// any model), a standalone search-provider id, or `nil` for no web
    /// search. Nullable column added by the `v6_searchBackend` migration; old
    /// rows decode as `nil`.
    ///
    /// The `"native"` ⇒ native-`kind` pairing is an **add-time invariant**
    /// established by the Add-Model web-search picker, which resolves
    /// `kind`/`baseURL` from the catalog's
    /// `nativeSearchAdapter`/`nativeSearchBaseURL`; it is not enforced by this
    /// type. `"debug"` leaves the `kind` as `.openAICompatible` (or `.debug`
    /// for the seeded mock row) — the mock backend rides any provider.
    public var providerId: String?
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
            maxContextTokens: maxContextTokens,
            searchBackend: searchBackend
        )
    }
}
