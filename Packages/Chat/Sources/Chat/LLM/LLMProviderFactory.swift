import Core
import Foundation

/// Single source of truth for "given a persisted model row, which live
/// `LLMProvider` does this binary build for it?" Both composition paths —
/// the launch-time `AppBootstrapSupport.hydrateProviders` loop and the
/// Settings-time `SettingsViewModel.registerProvider` — call through here so
/// the per-kind dispatch can't drift between them as adapters are added.
///
/// Returns `nil` when no provider can be built for the row in the current
/// binary:
/// - an `.appleFoundation` row on a device where AFM is unavailable, or
/// - a native-search kind whose adapter hasn't shipped
///   (`!record.kind.hasProviderAdapter`), or
/// - an HTTP-backed kind when no `http` client was supplied (tests/previews
///   that don't wire one).
///
/// Callers treat a `nil` for a non-buildable native kind as "skip + log";
/// `nil` for an unavailable AFM device is the silent expected path.
///
/// - Parameters:
///   - record: The persisted configuration row.
///   - apiKey: BYOK credential already resolved from the Keychain by the
///     caller (the factory has no repository/Keychain dependency).
///   - http: Streaming HTTP client for the network-backed kinds. May be
///     `nil`; the network kinds then return `nil`.
///   - toolRegistry: Needed by `AppleFoundationLLMProvider`.
///   - appleFoundationAvailability: Gates the `.appleFoundation` arm.
public func makeLLMProvider(
    for record: ModelConfigurationRecord,
    apiKey: String?,
    http: HTTPClient?,
    toolRegistry: ToolRegistry,
    appleFoundationAvailability: AppleFoundationAvailability
) -> (any LLMProvider)? {
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
        guard appleFoundationAvailability.isAvailable else { return nil }
        return AppleFoundationLLMProvider(
            id: record.id,
            availability: appleFoundationAvailability,
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
