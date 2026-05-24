import Core
import Foundation

/// One model entry inside a provider's catalog. Drives the Add-Model
/// "Model" dropdown and provides the per-model defaults (max-context
/// cap, thinking capability) that the form prefills and validates
/// against.
public struct LLMCatalogModel: Equatable, Sendable, Identifiable {
    /// Wire-level model identifier sent to the provider (e.g.
    /// "gpt-5", "gemini-2.5-pro"). Also used as the row's `modelId`
    /// in the persisted `ModelConfigurationRecord`.
    public let id: String
    /// Human-facing label rendered in the dropdown and auto-assigned
    /// as the `ModelConfigurationRecord.name` when the user picks a
    /// built-in provider (the Name field is hidden in that case).
    public let displayName: String
    /// Upper bound the Add-Model form enforces on the Context Window
    /// field. Users may set a smaller value but not exceed this.
    public let maxContextTokens: Int
    /// Whether the model supports an extended-thinking / reasoning
    /// pass. Drives both the visibility of the Supports-Thinking
    /// toggle in the form and its default value when shown.
    public let supportsThinking: Bool

    public init(
        id: String,
        displayName: String,
        maxContextTokens: Int,
        supportsThinking: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.maxContextTokens = maxContextTokens
        self.supportsThinking = supportsThinking
    }
}

/// One provider in the Add-Model "Provider" dropdown. Holds the
/// default base URL and the catalog of models the second dropdown
/// renders. The `custom` entry is special-cased: it has no
/// `defaultBaseURL` and no catalog models — the user types both the
/// URL and the model id directly.
public struct LLMProviderCatalogEntry: Equatable, Sendable, Identifiable {
    /// Stable identifier used as the picker selection token and as
    /// the lookup key for `LLMProviderCatalog.entry(forID:)`.
    public let id: String
    public let displayName: String
    /// Maps to the persisted `LLMProviderKind` discriminator. Only
    /// Apple Intelligence uses `.appleFoundation`; the rest route
    /// through `OpenAICompatibleLLMProvider`.
    public let kind: LLMProviderKind
    /// Base URL the form auto-fills and hides when this provider is
    /// picked. Nil for Apple Intelligence (on-device, no URL) and
    /// for Custom (user supplies their own).
    public let defaultBaseURL: URL?
    public let models: [LLMCatalogModel]

    public init(
        id: String,
        displayName: String,
        kind: LLMProviderKind,
        defaultBaseURL: URL?,
        models: [LLMCatalogModel]
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.defaultBaseURL = defaultBaseURL
        self.models = models
    }
}

/// Hardcoded catalog of built-in providers and models the Add-Model
/// flow renders. Editing this file is the single touchpoint for
/// adjusting which providers/models appear in the picker, what URL
/// they map to, what context-window cap they enforce, and which
/// support thinking.
///
/// Anthropic uses its OpenAI-compat shim (`/v1/openai/`) so all
/// non-Apple entries share `OpenAICompatibleLLMProvider`. Adding a
/// native-Messages-API Anthropic adapter later would change Anthropic's
/// `kind` here and require a parallel provider registration in
/// `SettingsViewModel.registerProvider`.
public enum LLMProviderCatalog {
    /// Identifier of the Custom entry. Held as a constant rather
    /// than a string literal so visibility predicates can reference
    /// it without typo risk.
    public static let customProviderID = "custom"

    /// Identifier of the Apple Intelligence entry. Same rationale
    /// as `customProviderID`.
    public static let appleProviderID = "apple"

    /// All providers in dropdown order. Apple first so on-device
    /// users find it at the top; Custom last because it's the
    /// escape hatch.
    public static let all: [LLMProviderCatalogEntry] = [
        LLMProviderCatalogEntry(
            id: appleProviderID,
            displayName: "Apple Intelligence",
            kind: .appleFoundation,
            defaultBaseURL: nil,
            models: [
                LLMCatalogModel(
                    id: "system-default",
                    displayName: "Apple Intelligence",
                    maxContextTokens: 4_096,
                    supportsThinking: false
                ),
            ]
        ),
        LLMProviderCatalogEntry(
            id: "openai",
            displayName: "OpenAI",
            kind: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.openai.com/v1"),
            models: [
                // GPT-5.5 (released 2026-04-24) is OpenAI's current
                // frontier model, 1M-token context, thinking-capable.
                LLMCatalogModel(id: "gpt-5.5", displayName: "GPT-5.5", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gpt-5.5-pro", displayName: "GPT-5.5 Pro", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini", maxContextTokens: 400_000, supportsThinking: false),
                LLMCatalogModel(id: "gpt-5.4-nano", displayName: "GPT-5.4 nano", maxContextTokens: 400_000, supportsThinking: false),
            ]
        ),
        LLMProviderCatalogEntry(
            id: "anthropic",
            displayName: "Anthropic",
            kind: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.anthropic.com/v1/openai/"),
            models: [
                // Opus 4.7 (released 2026-04-16) ships a 1M-token
                // context window at standard pricing — no long-context
                // premium tier.
                LLMCatalogModel(id: "claude-opus-4-7", displayName: "Opus 4.7", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", maxContextTokens: 200_000, supportsThinking: true),
                LLMCatalogModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", maxContextTokens: 200_000, supportsThinking: false),
            ]
        ),
        LLMProviderCatalogEntry(
            id: "google",
            displayName: "Google",
            kind: .openAICompatible,
            defaultBaseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/"),
            models: [
                // Gemini 3.5 Flash is the newest mid-2026 iteration.
                // Gemini 3 Pro is the flagship; Gemini 3 Flash sits
                // between them as a faster-but-still-reasoning option.
                LLMCatalogModel(id: "gemini-3-pro", displayName: "Gemini 3 Pro", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gemini-3-flash", displayName: "Gemini 3 Flash", maxContextTokens: 1_000_000, supportsThinking: true),
            ]
        ),
        LLMProviderCatalogEntry(
            id: "xai",
            displayName: "xAI",
            kind: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.x.ai/v1"),
            models: [
                // Grok 4.3 (released 2026-04-30) is xAI's current
                // flagship — 1M context, three reasoning intensity
                // levels. Grok 3 and Grok 3 Mini were retired
                // 2026-05-15.
                LLMCatalogModel(id: "grok-4.3", displayName: "Grok 4.3", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "grok-4.1-fast", displayName: "Grok 4.1 Fast", maxContextTokens: 2_000_000, supportsThinking: false),
            ]
        ),
        LLMProviderCatalogEntry(
            id: customProviderID,
            displayName: "Custom",
            kind: .openAICompatible,
            defaultBaseURL: nil,
            models: []
        ),
    ]

    /// Look up a provider entry by its id. Returns nil when no entry
    /// matches — callers fall back to the Custom shape (no catalog
    /// constraints).
    public static func entry(forID providerID: String) -> LLMProviderCatalogEntry? {
        all.first(where: { $0.id == providerID })
    }

    /// Resolved (provider, model) pair for a given wire-level
    /// `modelId`. Used by the Add-Model edit flow to recover the
    /// catalog cap + auto-name + thinking-capability for an existing
    /// row. Returns nil for rows whose `modelId` isn't in any
    /// provider's catalog (truly custom configurations).
    public static func model(forModelId modelId: String) -> (provider: LLMProviderCatalogEntry, model: LLMCatalogModel)? {
        for entry in all {
            if let match = entry.models.first(where: { $0.id == modelId }) {
                return (entry, match)
            }
        }
        return nil
    }
}
