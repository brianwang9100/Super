import Core
import Foundation

/// Returns `nil` when the row lacks a required dependency or the adapter is unavailable.
public func makeLLMProvider(
    for record: ModelConfigurationRecord,
    apiKey: String?,
    http: HTTPClient?,
    toolRegistry: ToolRegistry,
    appleFoundationAvailability: AppleFoundationAvailability
) -> (any LLMProvider)? {
    switch record.kind {
    case .openAICompatible:
        // Corrupt or synced rows may violate the kind's URL requirement.
        guard let http, record.configuration.baseURL != nil else { return nil }
        return OpenAICompatibleLLMProvider(
            configuration: record.configuration,
            apiKey: apiKey,
            http: http
        )
    case .openAIResponses:
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
        guard let http, record.configuration.baseURL != nil else { return nil }
        return AnthropicNativeLLMProvider(
            configuration: record.configuration,
            apiKey: apiKey,
            http: http
        )
    case .geminiNative:
        guard let http, record.configuration.baseURL != nil else { return nil }
        return GeminiNativeLLMProvider(
            configuration: record.configuration,
            apiKey: apiKey,
            http: http
        )
    #if DEBUG
    case .debug:
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
