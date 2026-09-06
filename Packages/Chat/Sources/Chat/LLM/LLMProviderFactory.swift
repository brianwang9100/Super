import Core
import Foundation

/// Constructs the persisted model's provider for both bootstrap and Settings.
/// Known Apple models retain their identity while unavailable, never switching
/// between local and Private Cloud Compute (PCC) or another backend implicitly.
///
/// - Parameters:
///   - record: The persisted configuration row.
///   - apiKey: BYOK credential already resolved from the Keychain by the
///     caller (the factory has no repository/Keychain dependency).
///   - http: Streaming HTTP client for the network-backed kinds. May be
///     `nil`; the network kinds then return `nil`.
///   - toolRegistry: Needed by `AppleFoundationLLMProvider`.
///   - appleFoundationAvailability: Legacy local-only status injection for
///     previews and tests. Ignored when a model-specific status provider is supplied.
///   - appleFoundationStatusProvider: Refreshable local/PCC capability source.
/// - Returns: A provider, or `nil` for unknown Apple IDs or HTTP configurations
///   missing the required client or base URL.
public func makeLLMProvider(
    for record: ModelConfigurationRecord,
    apiKey: String?,
    http: HTTPClient?,
    toolRegistry: ToolRegistry,
    appleFoundationAvailability: AppleFoundationAvailability? = nil,
    appleFoundationStatusProvider: (any AppleFoundationModelStatusProvider)? = nil
) async -> (any LLMProvider)? {
    switch record.kind {
    case .openAICompatible:
        // Skip (don't crash) a row missing the `baseURL` the provider's init
        // requires — `baseURL` is a nullable column, and a corrupt/synced row
        // could carry `.openAICompatible` with `nil`. The init would
        // `preconditionFailure`; returning `nil` here means the row is dropped
        // gracefully and the first-registered fallback covers hydration.
        guard let http, record.configuration.baseURL != nil else { return nil }
        return OpenAICompatibleLLMProvider(
            configuration: record.configuration,
            apiKey: apiKey,
            http: http
        )
    case .openAIResponses:
        // Same nil-`baseURL` guard as `.openAICompatible`: the flip to
        // `hasProviderAdapter == true` routes these rows here, so a nil
        // `baseURL` must skip rather than hit the init's `preconditionFailure`
        // and crash on every launch.
        guard let http, record.configuration.baseURL != nil else { return nil }
        return OpenAIResponsesLLMProvider(
            configuration: record.configuration,
            apiKey: apiKey,
            http: http
        )
    case .appleFoundation:
        // `id` must match the record UUID so `setActive(id:)` can promote the
        // seeded `isSelected` row; a static fallback would silently fail.
        guard let model = AppleFoundationModel(rawValue: record.modelId) else { return nil }
        let statusProvider: any AppleFoundationModelStatusProvider
        if let appleFoundationStatusProvider {
            statusProvider = appleFoundationStatusProvider
        } else if let appleFoundationAvailability {
            statusProvider = FixedAppleFoundationModelStatusProvider(
                localAvailability: appleFoundationAvailability
            )
        } else {
            statusProvider = LiveAppleFoundationModelStatusProvider()
        }
        return await AppleFoundationLLMProvider.make(
            id: record.id,
            model: model,
            statusProvider: statusProvider,
            toolRegistry: toolRegistry
        )
    case .anthropicNative:
        // Same nil-`baseURL` guard as the other network kinds: the flip to
        // `hasProviderAdapter == true` routes these rows here, so a nil
        // `baseURL` must skip rather than hit the init's `preconditionFailure`.
        guard let http, record.configuration.baseURL != nil else { return nil }
        return AnthropicNativeLLMProvider(
            configuration: record.configuration,
            apiKey: apiKey,
            http: http
        )
    case .geminiNative:
        // Same nil-`baseURL` guard as the other network kinds: the flip to
        // `hasProviderAdapter == true` routes these rows here, so a nil
        // `baseURL` must skip rather than hit the init's `preconditionFailure`.
        guard let http, record.configuration.baseURL != nil else { return nil }
        return GeminiNativeLLMProvider(
            configuration: record.configuration,
            apiKey: apiKey,
            http: http
        )
    #if DEBUG
    case .debug:
        // One `.debug` kind, three providers — dispatch on `modelId` so the
        // canned-stream, annotate, and note debug rows each build their own
        // provider without churning the enum / `hasProviderAdapter` /
        // Settings switch (which all key off `kind == .debug`).
        switch record.modelId {
        case DebugAnnotateLLMProvider.modelID:
            return DebugAnnotateLLMProvider(id: record.id)
        case DebugNoteLLMProvider.modelID:
            return DebugNoteLLMProvider(id: record.id)
        case DebugReadLLMProvider.modelID:
            return DebugReadLLMProvider(id: record.id)
        case DebugSearchLLMProvider.modelID:
            return DebugSearchLLMProvider(id: record.id)
        case DebugHighlightLLMProvider.modelID:
            return DebugHighlightLLMProvider(id: record.id)
        case DebugTodoLLMProvider.modelID:
            return DebugTodoLLMProvider(id: record.id)
        default:
            // Carry the row's search backend so a seeded "Debug (mock
            // search)" row (`searchBackend == "debug"`) drives the
            // client-mock search path end-to-end in the simulator. Pass the
            // row's `name` as the picker label so the canned and mock-search
            // rows read distinctly (they share `modelId`, so the static label
            // alone made them indistinguishable — and unselectable apart).
            return DebugLLMProvider(
                id: record.id,
                searchBackend: record.searchBackend,
                modelDisplayName: record.name
            )
        }
    #endif
    }
}
