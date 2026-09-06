import Core
import Foundation

/// One model entry inside a provider's catalog. Drives the Add-Model
/// "Model" dropdown and provides the per-model defaults (max-context
/// cap, thinking capability) that the form prefills and validates
/// against.
public struct LLMCatalogModel: Equatable, Sendable, Identifiable {
    /// Provider model identifier, or an app-owned Apple variant identifier.
    /// Also persisted as `ModelConfigurationRecord.modelId`.
    public let id: String
    /// Human-facing label rendered in the dropdown and auto-assigned
    /// as the `ModelConfigurationRecord.name` when the user picks a
    /// built-in provider (the Name field is hidden in that case).
    /// Defaults to the wire id — the dropdown mixes curated catalog
    /// entries with live-fetched ids, and a curated pretty name next
    /// to raw ids read as two different lists. Only Apple overrides
    /// it: Apple's local/Private Cloud Compute (PCC) IDs are configuration tokens,
    /// and neither model is fetched from an HTTP model catalog.
    public let displayName: String
    /// Context-window cap for editable HTTP models, or fallback metadata for
    /// Apple's read-only models while their actual context window resolves.
    public let maxContextTokens: Int
    /// Whether the model supports an extended-thinking / reasoning
    /// pass. Drives both the visibility of the Supports-Thinking
    /// toggle in the form and its default value when shown.
    public let supportsThinking: Bool

    public init(
        id: String,
        displayName: String? = nil,
        maxContextTokens: Int,
        supportsThinking: Bool
    ) {
        self.id = id
        self.displayName = displayName ?? id
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
    /// Maps to the persisted protocol discriminator. Apple uses
    /// `.appleFoundation`; HTTP providers declare their native or compatible adapter.
    public let kind: LLMProviderKind
    /// Base URL the form auto-fills and hides when this provider is
    /// picked. Nil for Apple Intelligence (framework-managed, no URL) and
    /// for Custom (user supplies their own).
    public let defaultBaseURL: URL?
    /// The native provider `kind` this entry resolves to when the user
    /// enables native web search, or `nil` for providers without a native
    /// adapter (Apple, xAI, Custom). Selecting `Native (<Provider>)` in the
    /// Add-Model dropdown persists this as the row's `kind`; everything
    /// else keeps `.openAICompatible`. The dropdown's knowledge of "which
    /// providers ship a native adapter" comes solely from this field — a
    /// future native provider is a catalog edit, no UI change.
    public let nativeSearchAdapter: LLMProviderKind?
    /// Base URL for the native adapter, distinct from the
    /// `.openAICompatible` `defaultBaseURL` shim so a model can be added
    /// either way. Non-nil exactly when `nativeSearchAdapter` is.
    public let nativeSearchBaseURL: URL?
    public let models: [LLMCatalogModel]

    /// `true` when this provider ships a native web-search adapter.
    public var supportsNativeSearch: Bool { nativeSearchAdapter != nil }

    public init(
        id: String,
        displayName: String,
        kind: LLMProviderKind,
        defaultBaseURL: URL?,
        models: [LLMCatalogModel],
        nativeSearchAdapter: LLMProviderKind? = nil,
        nativeSearchBaseURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        // The two native-search fields are a unit: an adapter is useless
        // without its base URL and vice versa. Enforce the pairing at
        // construction so a mistyped catalog entry (or any future caller)
        // fails loudly rather than silently producing a half-configured
        // entry that `supportsNativeSearch` reports as capable.
        //
        // `precondition` (unlike `assert`) fires in **both** Debug and
        // Release — a mismatched entry would crash at first access to
        // `LLMProviderCatalog.all`. That's the intended behavior: the pair
        // is compile-time-constant data, so a violation is a programmer
        // error that should never ship. `nativeSearchFieldsArePaired` in
        // `SettingsModelDetailPaneCatalogTests` is the first line of defense
        // (catches a bad entry in CI before release); this is the
        // belt-and-suspenders backstop.
        precondition(
            (nativeSearchAdapter == nil) == (nativeSearchBaseURL == nil),
            "nativeSearchAdapter and nativeSearchBaseURL must both be set or both be nil"
        )
        self.kind = kind
        self.defaultBaseURL = defaultBaseURL
        self.models = models
        self.nativeSearchAdapter = nativeSearchAdapter
        self.nativeSearchBaseURL = nativeSearchBaseURL
    }
}

/// Hardcoded catalog of built-in providers and models the Add-Model
/// flow renders. Editing this file is the single touchpoint for
/// adjusting which providers/models appear in the picker, what URL
/// they map to, what context-window cap they enforce, and which
/// support thinking.
///
/// Most non-Apple entries use an OpenAI-compat shim (`/v1/openai/`) for the
/// default (non-search) path, so their `kind` is `.openAICompatible`. **Google
/// is the exception**: it defaults to the native Gemini adapter
/// (`kind == .geminiNative`) because Gemini 3 thinking models require
/// `thoughtSignature` round-tripping on tool calls. A provider's *native*
/// web-search adapter is declared separately via `nativeSearchAdapter` /
/// `nativeSearchBaseURL`; when the user enables native search, the row's
/// persisted `kind` and `baseURL` are resolved from those fields at add-time.
public enum LLMProviderCatalog {
    /// Identifier of the Custom entry. Held as a constant rather
    /// than a string literal so visibility predicates can reference
    /// it without typo risk.
    public static let customProviderID = "custom"

    /// Identifier of the Apple Intelligence entry. Same rationale
    /// as `customProviderID`.
    public static let appleProviderID = "apple"

    // Native web-search endpoint bases. Held as named constants — distinct
    // from each provider's `defaultBaseURL` OpenAI-compat shim — so the
    // catalog entries below and the native adapters (PR3a/3b/3c) reference
    // one source of truth rather than re-typing the literal. Force-unwrapped:
    // these are compile-time-constant valid URLs, and a typo should fail
    // the catalog invariant tests, not silently produce a nil base URL.
    /// Anthropic Messages API base (`/v1/messages` appended by the adapter).
    public static let anthropicNativeBaseURL = URL(string: "https://api.anthropic.com/v1")!
    /// Gemini `generateContent` base (distinct from the `/openai` shim).
    public static let geminiNativeBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    /// OpenAI Responses API base (`/responses` appended by the adapter).
    /// ⚠️ Byte-for-byte identical to the OpenAI compat entry's
    /// `defaultBaseURL` — the Responses API and Chat Completions API share
    /// `/v1`, so a distinct constant can't disambiguate them.
    /// `SettingsModelDetailPane.resolveEditProvider` therefore classifies
    /// `.openAIResponses` rows by `kind` *before* its URL-match branch (and
    /// independent of `hasProviderAdapter`, which flipped `true` when the
    /// adapter shipped) — otherwise such a row would URL-match the compat
    /// "openai" entry and open the edit pane in the wrong (compat) mode. No
    /// native-kind row can be *created* yet (the Add-Model native option ships
    /// with PR5), so this is currently exercised only by tests.
    public static let openAIResponsesBaseURL = URL(string: "https://api.openai.com/v1")!

    /// All providers in dropdown order. Apple first so its local and cloud
    /// models are easy to find; Custom last because it's the
    /// escape hatch.
    public static let all: [LLMProviderCatalogEntry] = [
        LLMProviderCatalogEntry(
            id: appleProviderID,
            displayName: "Apple",
            kind: .appleFoundation,
            defaultBaseURL: nil,
            models: [
                // Static metadata is available on iOS 26 too; actual context
                // windows and readiness come from model-specific status.
                LLMCatalogModel(
                    id: AppleFoundationModel.local.rawValue,
                    displayName: AppleFoundationModel.local.displayName,
                    maxContextTokens: AppleFoundationModel.local.fallbackContextTokens,
                    supportsThinking: false
                ),
                LLMCatalogModel(
                    id: AppleFoundationModel.privateCloudCompute.rawValue,
                    displayName: AppleFoundationModel.privateCloudCompute.displayName,
                    maxContextTokens: AppleFoundationModel.privateCloudCompute.fallbackContextTokens,
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
                LLMCatalogModel(id: "gpt-5.5", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gpt-5.5-pro", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gpt-5.4-mini", maxContextTokens: 400_000, supportsThinking: false),
                LLMCatalogModel(id: "gpt-5.4-nano", maxContextTokens: 400_000, supportsThinking: false),
            ],
            nativeSearchAdapter: .openAIResponses,
            nativeSearchBaseURL: openAIResponsesBaseURL
        ),
        LLMProviderCatalogEntry(
            id: "anthropic",
            displayName: "Anthropic",
            // Anthropic defaults to the **native** Messages API (not the
            // `/v1/openai/` compat shim the OpenAI-family providers use): only
            // the native path can carry explicit `cache_control` breakpoints,
            // so every Anthropic turn benefits from prompt caching. Mirrors
            // Google's default-native entry below; the compat shim still works
            // for a Custom-provider Anthropic URL. New rows seed native; a
            // ChatDatabase migration (`v10_anthropicNativeDefault`) flips
            // pre-existing default-shim rows.
            kind: .anthropicNative,
            defaultBaseURL: anthropicNativeBaseURL,
            models: [
                // Opus 4.7 (released 2026-04-16) ships a 1M-token
                // context window at standard pricing — no long-context
                // premium tier.
                // Anthropic wire ids accept both dateless aliases and
                // fully-qualified dated forms. Haiku 4.5 ships only
                // under its dated id per the current model card
                // (`-20251001`); Opus 4.7 and Sonnet 4.6 accept the
                // dateless aliases — using them keeps the catalog
                // readable and the alias resolves to the current
                // dated build server-side.
                LLMCatalogModel(id: "claude-opus-4-7", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "claude-sonnet-4-6", maxContextTokens: 200_000, supportsThinking: true),
                LLMCatalogModel(id: "claude-haiku-4-5-20251001", maxContextTokens: 200_000, supportsThinking: false),
            ],
            nativeSearchAdapter: .anthropicNative,
            nativeSearchBaseURL: anthropicNativeBaseURL
        ),
        LLMProviderCatalogEntry(
            id: "google",
            displayName: "Google",
            // Google defaults to the **native** Gemini `generateContent` adapter
            // (not the `/v1beta/openai/` compat shim the other providers use):
            // Gemini 3 thinking models require `thoughtSignature` round-tripping
            // on tool calls, which the native adapter handles first-class. The
            // OpenAI-compat path still works for a Custom-provider Google URL.
            kind: .geminiNative,
            defaultBaseURL: geminiNativeBaseURL,
            models: [
                // Gemini 3.5 Flash is the newest mid-2026 iteration.
                // Gemini 3 Pro is the flagship; Gemini 3 Flash sits
                // between them as a faster-but-still-reasoning option.
                LLMCatalogModel(id: "gemini-3-pro", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gemini-3.5-flash", maxContextTokens: 1_000_000, supportsThinking: true),
                LLMCatalogModel(id: "gemini-3-flash", maxContextTokens: 1_000_000, supportsThinking: true),
            ],
            nativeSearchAdapter: .geminiNative,
            nativeSearchBaseURL: geminiNativeBaseURL
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
                // 2026-05-15; Grok 4.1 Fast is deprecated (pruned
                // 2026-06-11 — the live list resurfaces it if xAI
                // still serves the id).
                LLMCatalogModel(id: "grok-4.3", maxContextTokens: 1_000_000, supportsThinking: true),
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

    /// Context-window cap assigned to a fetched model id that isn't in the
    /// catalog. A conservative middle-of-the-road default — the user can
    /// edit the Context Window field up or down once the model is picked.
    public static let defaultFetchedMaxContextTokens = 200_000

    /// Merge a live "list models" result for `providerID` into the
    /// `LLMCatalogModel` list the Add-Model "Model" dropdown renders.
    ///
    /// A fetched id that matches a catalog model keeps that model's curated
    /// metadata (`maxContextTokens`, `supportsThinking`); a fetched id with
    /// no catalog match becomes a default `LLMCatalogModel`
    /// (`defaultFetchedMaxContextTokens` cap, thinking off) the user can
    /// still edit. Every entry renders its wire id — curated display names
    /// were removed (2026-06-11) because the mixed pretty-name/raw-id list
    /// read as inconsistent. Duplicate fetched ids collapse to first
    /// occurrence.
    ///
    /// Ordering keeps the curated models on top: catalog-known ids appear
    /// first **in catalog order** (not fetch order — the catalog is the
    /// editorial ranking), then the unknown ids alphabetically. Pure, so
    /// the reconciliation is unit-testable without any network.
    public static func reconcile(providerID: String, fetchedModelIDs: [String]) -> [LLMCatalogModel] {
        // Collapse duplicates, preserving first-seen order for the unknown
        // tail's stability before the final sort.
        var seen = Set<String>()
        let uniqueFetched = fetchedModelIDs.filter { seen.insert($0).inserted }
        let fetchedSet = Set(uniqueFetched)

        let catalogModels = entry(forID: providerID)?.models ?? []
        // Known: catalog models the API actually returned, in catalog order.
        let known = catalogModels.filter { fetchedSet.contains($0.id) }
        let knownIDs = Set(known.map(\.id))
        // Unknown: fetched ids with no catalog entry, alphabetized.
        let unknown = uniqueFetched
            .filter { !knownIDs.contains($0) }
            .sorted()
            .map {
                LLMCatalogModel(
                    id: $0,
                    maxContextTokens: defaultFetchedMaxContextTokens,
                    supportsThinking: false
                )
            }
        return known + unknown
    }
}
