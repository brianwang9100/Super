#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Pixel-stable snapshots of `SettingsSheet`'s content across themes and
/// panes. The sheet now presents via a native `.sheet` (the system owns the
/// scrim, drag bar, and rounded surface), so each scenario renders the sheet
/// content on a fixed-size neutral container — the presentation chrome is the
/// system's and out of scope for these content snapshots.
///
/// Note on the Dynamic Type XXL companions: post-`SuperTypography`, settings
/// text resolves through `typography.font(_ role:)` (system path, `relativeTo:
/// nil` per decision ④), so OS Dynamic Type does not enlarge it. The XXL
/// baselines are therefore byte-identical to their default-DT siblings and
/// act as fixed-chrome sentinels — a diff flags an accidental reintroduction
/// of Dynamic Type scaling to settings chrome. The app font-scale slider is
/// the axis these panes respond to.
@Suite("SettingsSheet snapshots", .serialized)
@MainActor
struct SettingsSheetSnapshotTests {
    /// Register Core's bundled brand fonts before any render so this suite
    /// is order-independent in the shared test process (the xctest host never
    /// runs the app's font registration). See SnapshotFontRegistration.
    init() { SnapshotFontRegistration.ensureRegistered() }
    private static let frame = CGSize(width: 402, height: 874)

    private static let appInfo = SuperAppInfo(bundleName: "Super", version: "0.3.1", build: "1")

    private static let sampleModels: [SettingsViewModel.ModelRow] = [
        // opus is the row used by the model-detail-edit snapshot — flag
        // `hasAPIKey: true` so the pane seeds the SecureField with the
        // placeholder bullets that signal "a key is already stored."
        .init(
            id: "opus", name: "Opus 4.7", monogram: "O4",
            endpoint: "api.example.com/v1", maxContextTokens: 200_000, isEnabled: true,
            baseURL: URL(string: "https://api.example.com/v1")!,
            modelId: "claude-opus-4-7", supportsThinking: true, hasAPIKey: true
        ),
        .init(id: "gpt", name: "GPT 5.5", monogram: "G5", endpoint: "api.example.com/v1", maxContextTokens: 256_000, isEnabled: true),
        .init(id: "qwen", name: "Qwen3.6", monogram: "Q", endpoint: "api.example.com/v1", maxContextTokens: 128_000, isEnabled: false),
        .init(id: "gemma", name: "Gemma 4", monogram: "G", endpoint: "api.example.com/v1", maxContextTokens: 64_000, isEnabled: true),
    ]

    /// `sampleModels` plus an Apple Foundation row — kept separate so
    /// it doesn't ripple into the populated-models / root / Dynamic
    /// Type XXL snapshots that consume `sampleModels` directly.
    private static let sampleModelsWithAppleFoundation: [SettingsViewModel.ModelRow] = sampleModels + [
        .init(
            id: "afm",
            name: "Apple Intelligence",
            monogram: "AI",
            endpoint: "",
            maxContextTokens: 4_096,
            isEnabled: true,
            kind: .appleFoundation,
            baseURL: nil,
            modelId: "system-default",
            supportsThinking: false,
            hasAPIKey: false
        ),
    ]

    #if DEBUG
    /// `sampleModels` plus the debug provider row. Exists only in DEBUG
    /// builds because `LLMProviderKind.debug` is itself DEBUG-only —
    /// outside DEBUG the case doesn't compile, so neither does this
    /// fixture or the snapshot tests that reach for it.
    private static let sampleModelsWithDebug: [SettingsViewModel.ModelRow] = sampleModels + [
        .init(
            id: "debug-canned",
            name: "Debug (canned)",
            monogram: "DB",
            endpoint: "",
            maxContextTokens: DebugLLMProvider.maxContextTokens,
            isEnabled: true,
            kind: .debug,
            baseURL: nil,
            modelId: DebugLLMProvider.modelID,
            supportsThinking: true,
            hasAPIKey: false
        ),
    ]
    #endif

    /// `sampleModels` plus a native-web-search OpenAI row (kind
    /// `.openAIResponses`, `searchBackend: "native"`). Edited, it resolves to
    /// the OpenAI provider with the "Web search" picker showing "Native
    /// (OpenAI)" — the headline state of this PR's picker.
    private static let sampleModelsWithNativeOpenAI: [SettingsViewModel.ModelRow] = sampleModels + [
        .init(
            id: "openai-native", name: "GPT-5.5", monogram: "G5",
            endpoint: "api.openai.com/v1", maxContextTokens: 1_000_000, isEnabled: true,
            kind: .openAIResponses,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            modelId: "gpt-5.5", supportsThinking: true, hasAPIKey: true,
            searchBackend: "native"
        ),
    ]

    /// `sampleModels` plus a native Google row whose `modelId` is no longer
    /// in the curated catalog (a catalog-pruned model). Edited, it must
    /// render the provider-only "Google" header, the Model dropdown showing
    /// the raw stored wire id (via the stored-model union), and an enabled
    /// Save — the state that was Save-bricked before edit-mode model
    /// editing shipped.
    private static let sampleModelsWithOffCatalogGoogle: [SettingsViewModel.ModelRow] = sampleModels + [
        .init(
            id: "google-legacy", name: "Gemini 2.5 Pro", monogram: "G2",
            endpoint: "generativelanguage.googleapis.com/v1beta",
            maxContextTokens: 1_000_000, isEnabled: true,
            kind: .geminiNative,
            baseURL: LLMProviderCatalog.geminiNativeBaseURL,
            modelId: "gemini-2.5-pro", supportsThinking: true, hasAPIKey: true,
            searchBackend: "native"
        ),
    ]

    #if DEBUG
    /// `sampleModels` plus a debug row wired to the client-mock search backend
    /// (`searchBackend: "debug"`). Edited, the "Web search" picker shows
    /// "Debug (mock)". DEBUG-only (the case + option are compiled out of
    /// Release).
    private static let sampleModelsWithDebugSearch: [SettingsViewModel.ModelRow] = sampleModels + [
        .init(
            id: "debug-mock-search", name: "Debug (mock search)", monogram: "DB",
            endpoint: "", maxContextTokens: DebugLLMProvider.maxContextTokens, isEnabled: true,
            kind: .debug, baseURL: nil, modelId: DebugLLMProvider.modelID,
            supportsThinking: true, hasAPIKey: false, searchBackend: "debug"
        ),
    ]
    #endif

    /// Fetched-list fixture for the unlocked create-flow snapshots: two
    /// catalog ids plus one unknown id, reconciled once so the light/dark/XXL
    /// variants render the identical dropdown.
    private static let openAIUnlockedFetchedModels = [
        "openai": LLMProviderCatalog.reconcile(
            providerID: "openai",
            fetchedModelIDs: ["gpt-5.5", "gpt-5.4-mini", "gpt-6-preview"]
        ),
    ]

    // `ToolRow.name`/`summary` carry the user-facing display name + short
    // description (resolved from `LLMTool.displayName`/`summary`), never the
    // LLM-facing tool prompt. Two enabled tools so `SettingsRootPane`'s
    // "N enabled" value stays "2 enabled".
    private static let sampleTools: [SettingsViewModel.ToolRow] = [
        .init(id: "bible.annotate", name: "Bible annotations", summary: "Writes a markdown study summary for a passage.", isEnabled: true),
        // Disabled so the *enabled* count stays at 2 (leaving SettingsRootPane's
        // "N enabled" Tools-row value and its baselines unchanged), and to show
        // the toggle's off state in the snapshot.
        .init(id: "time.now", name: "Current time", summary: "Reports the current date and time.", isEnabled: false),
        // Memory is enabled so the gear affordance (visible only when both
        // enabled AND configurable) renders.
        .init(
            id: MemoryTool.toolID,
            name: "Memory",
            summary: "Remembers your preferences across conversations.",
            isEnabled: true,
            configPane: .memory
        ),
    ]

    @Test("root pane in light")
    func rootLight() async {
        await verify(theme: .vellumLight, pane: .root, name: "settings_root_light")
    }

    @Test("root pane in dark")
    func rootDark() async {
        await verify(theme: .vellumDark, pane: .root, name: "settings_root_dark")
    }

    @Test("models pane populated")
    func modelsPopulated() async {
        await verify(theme: .vellumLight, pane: .models, name: "settings_models_light")
    }

    // Models pane presented as the sheet's *modal root* — the composer's
    // "Manage models…" entry. Unlike `modelsPopulated` (pushed atop the
    // Settings root, back chevron), the leading header button here is a
    // close-✕ that dismisses the whole sheet. Light / dark / sepia covers the
    // theme branches (the AGENTS.md §3 minimum matrix); the card list itself
    // is already pinned across Dynamic Type by the pushed `models` variants.
    @Test("models pane as modal root (close button)")
    func modelsPaneAsModalRoot() async {
        await verifyModelsPaneAsModalRoot(
            theme: .vellumLight,
            name: "settings_models_root_light"
        )
    }

    @Test("models pane as modal root (close button, dark)")
    func modelsPaneAsModalRootDark() async {
        await verifyModelsPaneAsModalRoot(
            theme: .vellumDark,
            name: "settings_models_root_dark"
        )
    }

    private func verifyModelsPaneAsModalRoot(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) async {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        // Seed the modal root before building the harness so the sheet renders
        // Models at the base of the stack with a close-✕ leading button.
        viewModel.rootPane = .models
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .models,
            presentAsRoot: true
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    @Test("models pane with AFM row when AFM is available")
    func modelsPaneWithAFMAvailable() async {
        await verifyModelsPaneWithAFM(
            theme: .vellumLight,
            availability: .available,
            name: "settings_models_afm_available_light"
        )
    }

    @Test("models pane with AFM row when AFM is available (dark)")
    func modelsPaneWithAFMAvailableDark() async {
        await verifyModelsPaneWithAFM(
            theme: .vellumDark,
            availability: .available,
            name: "settings_models_afm_available_dark"
        )
    }

    @Test("models pane with AFM row when AFM is unavailable (modelNotReady)")
    func modelsPaneWithAFMModelNotReady() async {
        await verifyModelsPaneWithAFM(
            theme: .vellumLight,
            availability: .unavailable(.modelNotReady),
            name: "settings_models_afm_model_not_ready_light"
        )
    }

    @Test("models pane with AFM row when AFM is unavailable (deviceNotEligible)")
    func modelsPaneWithAFMDeviceNotEligible() async {
        await verifyModelsPaneWithAFM(
            theme: .vellumLight,
            availability: .unavailable(.deviceNotEligible),
            name: "settings_models_afm_device_not_eligible_light"
        )
    }

    @Test("models pane with AFM row when AFM is unavailable (modelNotReady, dark)")
    func modelsPaneWithAFMModelNotReadyDark() async {
        await verifyModelsPaneWithAFM(
            theme: .vellumDark,
            availability: .unavailable(.modelNotReady),
            name: "settings_models_afm_model_not_ready_dark"
        )
    }

    @Test("models pane with AFM row when AFM is unavailable (appleIntelligenceNotEnabled)")
    func modelsPaneWithAFMAppleIntelligenceNotEnabled() async {
        await verifyModelsPaneWithAFM(
            theme: .vellumLight,
            availability: .unavailable(.appleIntelligenceNotEnabled),
            name: "settings_models_afm_apple_intelligence_off_light"
        )
    }

    // Dynamic Type XXL companion per AGENTS.md §Testing.3 ("at minimum
    // one larger Dynamic Type size"). Models pane card layout — monogram
    // tile + two-line text stack + trailing toggle — is the most likely
    // surface to regress at XXL, so this is the variant we anchor.
    @Test("dynamic type XXL on models pane with AFM row")
    func modelsPaneWithAFMXXL() async {
        await verifyModelsPaneWithAFM(
            theme: .vellumLight,
            availability: .available,
            name: "settings_models_afm_available_light_xxl",
            dynamicType: .xxLarge
        )
    }

    #if DEBUG
    // Coverage for the DEBUG-only `case .debug:` arms in
    // `SettingsModelsPane.isModelAvailable(for:)` and `subtitle(for:)`
    // (PR #92 review). The row renders with monogram `DB`, name "Debug
    // (canned)", and subtitle `8K ctx · canned responses` from the
    // debug-arm code path; `isAvailable == true` keeps the toggle on
    // and the row enabled. Light + dark covers the theme branches; the
    // monogram/label/subtitle layout itself is already pinned at
    // Dynamic Type XXL by `modelsPaneWithAFMXXL`, so we don't duplicate
    // that variant for the debug row.
    @Test("models pane with debug provider row")
    func modelsPaneWithDebug() async {
        await verifyModelsPaneWithDebug(
            theme: .vellumLight,
            name: "settings_models_debug_light"
        )
    }

    @Test("models pane with debug provider row (dark)")
    func modelsPaneWithDebugDark() async {
        await verifyModelsPaneWithDebug(
            theme: .vellumDark,
            name: "settings_models_debug_dark"
        )
    }

    private func verifyModelsPaneWithDebug(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) async {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModelsWithDebug,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .models
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }
    #endif

    // Coverage for the native-web-search arms in
    // `SettingsModelsPane.isModelAvailable(for:)` and `subtitle(for:)`
    // (PR2 review). A `.anthropicNative` row folds into the same
    // `.openAICompatible` arm: always available, "Nk ctx · endpoint"
    // subtitle. The row carries `searchBackend: "native"` and a non-shim
    // `endpoint` (api.anthropic.com/v1, not /openai/) so a regression that
    // mis-routes a native kind — e.g. to the AFM arm (would gate
    // availability on AFM + swap the subtitle) — is caught. Light / dark /
    // sepia covers the theme branches (the AGENTS.md §3 minimum matrix);
    // the card layout is already pinned at Dynamic Type XXL by
    // `modelsPaneWithAFMXXL`.
    @Test("models pane with a native-web-search row")
    func modelsPaneWithNativeSearch() async {
        await verifyModelsPaneWithNativeSearch(
            theme: .vellumLight,
            name: "settings_models_native_search_light"
        )
    }

    @Test("models pane with a native-web-search row (dark)")
    func modelsPaneWithNativeSearchDark() async {
        await verifyModelsPaneWithNativeSearch(
            theme: .vellumDark,
            name: "settings_models_native_search_dark"
        )
    }

    private func verifyModelsPaneWithNativeSearch(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) async {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModels + [
                .init(
                    id: "opus-native",
                    name: "Opus 4.7 (native search)",
                    monogram: "ON",
                    endpoint: "api.anthropic.com/v1",
                    maxContextTokens: 1_000_000,
                    isEnabled: true,
                    kind: .anthropicNative,
                    baseURL: URL(string: "https://api.anthropic.com/v1"),
                    modelId: "claude-opus-4-7",
                    supportsThinking: true,
                    hasAPIKey: true,
                    searchBackend: "native"
                ),
            ],
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .models
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    // MARK: - Title-summarization footer

    @Test("models pane title-summarization footer: off (no model list)")
    func modelsPaneTitlingOff() async {
        await verifyModelsPaneTitling(
            theme: .vellumLight,
            settings: Self.titleSettings(enabled: false),
            name: "settings_models_titling_off_light"
        )
    }

    @Test("models pane title-summarization footer: off (dark)")
    func modelsPaneTitlingOffDark() async {
        await verifyModelsPaneTitling(
            theme: .vellumDark,
            settings: Self.titleSettings(enabled: false),
            name: "settings_models_titling_off_dark"
        )
    }

    @Test("models pane title-summarization footer: automatic default highlights the AFM row")
    func modelsPaneTitlingAutomatic() async {
        await verifyModelsPaneTitling(
            theme: .vellumLight,
            settings: Self.titleSettings(enabled: true, recordId: nil),
            name: "settings_models_titling_automatic_light"
        )
    }

    @Test("models pane title-summarization footer: automatic default (dark)")
    func modelsPaneTitlingAutomaticDark() async {
        await verifyModelsPaneTitling(
            theme: .vellumDark,
            settings: Self.titleSettings(enabled: true, recordId: nil),
            name: "settings_models_titling_automatic_dark"
        )
    }

    @Test("models pane title-summarization footer: an explicit model is selected")
    func modelsPaneTitlingExplicitModel() async {
        await verifyModelsPaneTitling(
            theme: .vellumLight,
            availability: .available,
            settings: Self.titleSettings(enabled: true, recordId: "opus"),
            name: "settings_models_titling_explicit_light"
        )
    }

    @Test("models pane title-summarization footer: explicit model selected (dark)")
    func modelsPaneTitlingExplicitModelDark() async {
        await verifyModelsPaneTitling(
            theme: .vellumDark,
            availability: .available,
            settings: Self.titleSettings(enabled: true, recordId: "opus"),
            name: "settings_models_titling_explicit_dark"
        )
    }

    /// `ChatSettings.default` with the two title-summarization knobs set.
    /// `recordId` is the summarizer row's **record id** (`ModelRow.id`), the
    /// unique identity the picker now matches on.
    private static func titleSettings(enabled: Bool, recordId: String? = nil) -> ChatSettings {
        var settings = ChatSettings.default
        settings.summarizeTitlesEnabled = enabled
        settings.titleModelId = recordId
        return settings
    }

    private func verifyModelsPaneTitling(
        theme: SuperTheme.Identifier,
        availability: AppleFoundationAvailability = .available,
        settings: ChatSettings,
        name: String,
        function: String = #function
    ) async {
        let viewModel = makeViewModel(appleFoundationAvailability: availability)
        viewModel._setSnapshotState(
            settings: settings,
            models: Self.sampleModelsWithAppleFoundation,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .models
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func verifyModelsPaneWithAFM(
        theme: SuperTheme.Identifier,
        availability: AppleFoundationAvailability,
        name: String,
        dynamicType: DynamicTypeSize = .large,
        function: String = #function
    ) async {
        let viewModel = makeViewModel(appleFoundationAvailability: availability)
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModelsWithAppleFoundation,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .models
        )
        .superTheme(.make(theme))
        .dynamicTypeSize(dynamicType)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    // Per-provider create-flow snapshots — one row per entry in
    // `LLMProviderCatalog.all`, light + dark each. Each one captures
    // the visible-field set the provider's catalog entry dictates.
    // OpenAI/Anthropic/Google/xAI render the key-first LOCKED state
    // (Provider dropdown + API Key only — the Model/Max-context/
    // Thinking/Web-search rows stay hidden until the key has content;
    // see the `_unlocked` snapshots for the revealed state). Apple
    // hides URL/Name/Key/Thinking and keeps Provider + Model stacked;
    // Custom shows every field (no live list to gate on).

    @Test("model detail create flow — Apple Intelligence selected")
    func modelDetailProviderApple() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .apple,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_apple_light"
        )
    }

    @Test("model detail create flow — Apple Intelligence selected (dark)")
    func modelDetailProviderAppleDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .apple,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_apple_dark"
        )
    }

    @Test("model detail create flow — OpenAI selected")
    func modelDetailProviderOpenAI() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_openai_light"
        )
    }

    @Test("model detail create flow — OpenAI selected (dark)")
    func modelDetailProviderOpenAIDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_openai_dark"
        )
    }

    @Test("model detail create flow — Anthropic selected")
    func modelDetailProviderAnthropic() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .anthropic,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_anthropic_light"
        )
    }

    @Test("model detail create flow — Anthropic selected (dark)")
    func modelDetailProviderAnthropicDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .anthropic,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_anthropic_dark"
        )
    }

    @Test("model detail create flow — Google selected")
    func modelDetailProviderGoogle() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_google_light"
        )
    }

    @Test("model detail create flow — Google selected (dark)")
    func modelDetailProviderGoogleDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_google_dark"
        )
    }

    @Test("model detail create flow — xAI selected")
    func modelDetailProviderXAI() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .xai,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_xai_light"
        )
    }

    @Test("model detail create flow — xAI selected (dark)")
    func modelDetailProviderXAIDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .xai,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_xai_dark"
        )
    }

    @Test("model detail create flow — Custom selected (all fields visible)")
    func modelDetailProviderCustom() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .custom,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_custom_light"
        )
    }

    @Test("model detail create flow — Custom selected (dark)")
    func modelDetailProviderCustomDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .custom,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_custom_dark"
        )
    }

    // Apple-disabled state: AFM unavailable on this device, Custom
    // is the active provider, and the Apple entry in the Provider
    // dropdown is the locked one. We can't capture the dropdown's
    // expanded menu in a steady-state snapshot, so this pins the
    // collapsed row's visual state when Custom is the active pick.
    @Test("model detail create flow — Apple provider locked (AFM unavailable)")
    func modelDetailProviderAppleDisabled() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .custom,
            availability: .unavailable(.appleIntelligenceNotEnabled),
            existingAppleFoundation: false,
            name: "settings_model_detail_apple_disabled_light"
        )
    }

    @Test("model detail create flow — Apple provider locked (dark)")
    func modelDetailProviderAppleDisabledDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .custom,
            availability: .unavailable(.appleIntelligenceNotEnabled),
            existingAppleFoundation: false,
            name: "settings_model_detail_apple_disabled_dark"
        )
    }

    // Dynamic Type XXL anchor per Chat AGENTS.md's
    // `light/dark/sepia × default × XXL` matrix. Custom is picked
    // because it exercises the widest set of visible rows (Provider
    // dropdown + Name + Base URL + Model ID + API Key + Max Context
    // + Thinking toggle), so a Dynamic Type regression in row
    // truncation, label wrapping, or picker chevron alignment
    // shows up here.
    @Test("dynamic type XXL on model detail create flow — Custom")
    func modelDetailProviderCustomXXL() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .custom,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_custom_light_xxl",
            dynamicType: .xxLarge
        )
    }

    // Inline-error state for the Max Context field after the user
    // typed an over-cap value and tapped Save. Uses the test seam
    // `initialModelDetailContextWindowError` to pre-set the error
    // without simulating a Save tap (plus a seeded key so the gated
    // Max-context row renders at all). Per AGENTS.md §Testing.3 —
    // SwiftUI views ship snapshots for their error state.
    @Test("model detail create flow — context-window over-cap error (light)")
    func modelDetailProviderContextWindowError() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_context_error_light",
            contextWindowError: "Maximum context for this model is 1,000,000 tokens.",
            apiKey: "sk-snapshot"
        )
    }

    @Test("model detail create flow — context-window over-cap error (dark)")
    func modelDetailProviderContextWindowErrorDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_context_error_dark",
            contextWindowError: "Maximum context for this model is 1,000,000 tokens.",
            apiKey: "sk-snapshot"
        )
    }

    // The unlocked create-flow state: key typed, live list fetched. Pins
    // the full key-first reveal — Provider, API Key, then Model (showing a
    // live id), Max context, Thinking, Web search — and that a fetched
    // list (including a non-catalog id) drives the dropdown.
    @Test("model detail create flow — key entered, live models fetched (light)")
    func modelDetailProviderOpenAIUnlocked() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_openai_unlocked_light",
            apiKey: "sk-snapshot",
            fetchedModels: Self.openAIUnlockedFetchedModels
        )
    }

    @Test("model detail create flow — key entered, live models fetched (dark)")
    func modelDetailProviderOpenAIUnlockedDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_openai_unlocked_dark",
            apiKey: "sk-snapshot",
            fetchedModels: Self.openAIUnlockedFetchedModels
        )
    }

    // Dynamic Type XXL on the unlocked state — the changed surface of the
    // key-first redesign (Custom's XXL anchor covers the ungated layout).
    @Test("dynamic type XXL on model detail create flow — unlocked OpenAI")
    func modelDetailProviderOpenAIUnlockedXXL() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_openai_unlocked_light_xxl",
            apiKey: "sk-snapshot",
            fetchedModels: Self.openAIUnlockedFetchedModels,
            dynamicType: .xxLarge
        )
    }

    // Key typed, fetch in flight: the Model row's refresh affordance swaps
    // to the spinner while the gated rows are already revealed.
    @Test("model detail create flow — key entered, models loading (light)")
    func modelDetailProviderOpenAIModelsLoading() async {
        await verifyCreateWithProvider(
            theme: .vellumLight,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_models_loading_light",
            apiKey: "sk-snapshot",
            loadingModelsProviderID: "openai"
        )
    }

    @Test("model detail create flow — key entered, models loading (dark)")
    func modelDetailProviderOpenAIModelsLoadingDark() async {
        await verifyCreateWithProvider(
            theme: .vellumDark,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_models_loading_dark",
            apiKey: "sk-snapshot",
            loadingModelsProviderID: "openai"
        )
    }

    // The live model-list fetch fell back to the curated catalog (no/bad key,
    // offline, etc.): the inline note renders under the Model dropdown.
    @Test("model detail create flow — live model-list fallback note (light)")
    func modelDetailModelListFallbackNote() async {
        await verifyCreateWithModelListNote(
            theme: .vellumLight,
            name: "settings_model_detail_model_list_note_light"
        )
    }

    @Test("model detail create flow — live model-list fallback note (dark)")
    func modelDetailModelListFallbackNoteDark() async {
        await verifyCreateWithModelListNote(
            theme: .vellumDark,
            name: "settings_model_detail_model_list_note_dark"
        )
    }

    private func verifyCreateWithModelListNote(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) async {
        let viewModel = makeViewModel(appleFoundationAvailability: .available)
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        viewModel._setModelListSnapshotState(
            modelListNote: ["openai": SettingsViewModel.modelListFallbackNote]
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: nil),
            initialModelDetailSelection: .openAI,
            // The note renders under the key-gated Model dropdown — seed a
            // key so the gated rows (and the note) are visible at all.
            initialModelDetailAPIKey: "sk-snapshot"
        )
        .superTheme(.make(theme))
        .dynamicTypeSize(.large)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    @Test("OpenAI setup offers explicit narration opt-in", arguments: ["light", "dark", "xxl"])
    func openAINarrationSetup(appearance: String) async {
        let audio = ProviderAudioSetup(snapshot: { ProviderAudioSnapshot(enabled: nil, source: nil, revision: 0) }, commit: { _, _, _, _ in })
        await verifyCreateWithProvider(
            theme: appearance == "dark" ? .vellumDark : .vellumLight, selection: .openAI,
            availability: .available, existingAppleFoundation: false, name: "openai_narration_\(appearance)",
            audioSetup: audio, apiKey: "sk-snapshot-only", dynamicType: appearance == "xxl" ? .xxLarge : .large,
            function: "openAINarrationSetup_\(appearance)"
        )
    }

    private func verifyCreateWithProvider(
        theme: SuperTheme.Identifier,
        selection: SettingsModelDetailPane.InitialSelection,
        availability: AppleFoundationAvailability,
        existingAppleFoundation: Bool,
        name: String,
        audioSetup: ProviderAudioSetup? = nil,
        contextWindowError: String? = nil,
        apiKey: String? = nil,
        fetchedModels: [String: [LLMCatalogModel]] = [:],
        loadingModelsProviderID: String? = nil,
        dynamicType: DynamicTypeSize = .large,
        function: String = #function
    ) async {
        let viewModel = makeViewModel(appleFoundationAvailability: availability, audioSetup: audioSetup)
        viewModel._setSnapshotState(
            settings: .default,
            models: existingAppleFoundation
                ? Self.sampleModelsWithAppleFoundation
                : Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        if !fetchedModels.isEmpty || loadingModelsProviderID != nil {
            viewModel._setModelListSnapshotState(
                fetchedModels: fetchedModels,
                loadingModelsProviderID: loadingModelsProviderID
            )
        }
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: nil),
            initialModelDetailSelection: selection,
            initialModelDetailContextWindowError: contextWindowError,
            initialModelDetailAPIKey: apiKey
        )
        .superTheme(.make(theme))
        .dynamicTypeSize(dynamicType)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    @Test("model detail seeded form (edit flow)")
    func modelDetailEdit() async {
        await verify(theme: .vellumLight, pane: .modelDetail(id: "opus"), name: "settings_model_detail_edit_light")
    }

    // Locks in the `baseURL == nil` init path introduced by the
    // provider-kind discriminator work: `_baseURLText` falls back
    // to the placeholder default when the row's URL is nil.
    @Test("model detail seeded form for Apple Foundation row")
    func modelDetailAppleFoundation() async {
        await verifyAppleFoundation(theme: .vellumLight, name: "settings_model_detail_afm_light")
    }

    // Dark companion per AGENTS.md §Testing.3.
    @Test("model detail seeded form for Apple Foundation row (dark)")
    func modelDetailAppleFoundationDark() async {
        await verifyAppleFoundation(theme: .vellumDark, name: "settings_model_detail_afm_dark")
    }

    // Dynamic Type XXL companion per AGENTS.md §Testing.3.
    @Test("dynamic type XXL on Apple Foundation model detail pane")
    func modelDetailAppleFoundationXXL() async {
        await verifyAppleFoundationXXL(theme: .vellumLight, name: "settings_model_detail_afm_light_xxl")
    }

    // Dark + XXL cell to fill the `light/dark/sepia × default/Dynamic
    // Type XXL` matrix called out in `Packages/Chat/AGENTS.md`.
    @Test("dynamic type XXL on Apple Foundation model detail pane (dark)")
    func modelDetailAppleFoundationXXLDark() async {
        await verifyAppleFoundationXXL(theme: .vellumDark, name: "settings_model_detail_afm_dark_xxl")
    }

    private func verifyAppleFoundationXXL(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) async {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModelsWithAppleFoundation,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: "afm")
        )
        .superTheme(.make(theme))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func verifyAppleFoundation(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) async {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModelsWithAppleFoundation,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: "afm")
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    // Dark companion for modelDetailEdit; locks in white-bullet contrast in dark per AGENTS.md §Testing.3.
    @Test("model detail seeded form (edit flow) in dark")
    func modelDetailEditDark() async {
        await verify(theme: .vellumDark, pane: .modelDetail(id: "opus"), name: "settings_model_detail_edit_dark")
    }

    // Dynamic Type XXL companion for modelDetailEdit; covers the "at minimum one larger Dynamic Type size" half of AGENTS.md §Testing.3.
    @Test("dynamic type XXL on model detail edit pane")
    func modelDetailEditXXL() async {
        let function = #function
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: "opus")
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_model_detail_edit_light_xxl", function: function)
    }

    // MARK: - Web-search backend picker (model detail)

    @Test("model detail edit — native web search selected (light)")
    func modelDetailNativeSearch() async {
        await verifyModelDetailEdit(
            theme: .vellumLight, models: Self.sampleModelsWithNativeOpenAI, id: "openai-native",
            name: "settings_model_detail_native_search_light"
        )
    }

    @Test("model detail edit — native web search selected (dark)")
    func modelDetailNativeSearchDark() async {
        await verifyModelDetailEdit(
            theme: .vellumDark, models: Self.sampleModelsWithNativeOpenAI, id: "openai-native",
            name: "settings_model_detail_native_search_dark"
        )
    }

    // Dynamic Type XXL covers the new "Web search" row's text reflow.
    @Test("dynamic type XXL on model detail edit — native web search selected")
    func modelDetailNativeSearchXXL() async {
        let function = #function
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModelsWithNativeOpenAI,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: "openai-native")
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_model_detail_native_search_light_xxl", function: function)
    }

    // MARK: - Edit mode with an off-catalog stored model

    @Test("model detail edit — off-catalog stored model stays selectable (light)")
    func modelDetailEditOffCatalogModel() async {
        await verifyModelDetailEdit(
            theme: .vellumLight, models: Self.sampleModelsWithOffCatalogGoogle, id: "google-legacy",
            name: "settings_model_detail_edit_offcatalog_light"
        )
    }

    @Test("model detail edit — off-catalog stored model stays selectable (dark)")
    func modelDetailEditOffCatalogModelDark() async {
        await verifyModelDetailEdit(
            theme: .vellumDark, models: Self.sampleModelsWithOffCatalogGoogle, id: "google-legacy",
            name: "settings_model_detail_edit_offcatalog_dark"
        )
    }

    // Dynamic Type XXL covers the dropdown row's reflow with a raw wire id.
    @Test("dynamic type XXL on model detail edit — off-catalog stored model")
    func modelDetailEditOffCatalogModelXXL() async {
        let function = #function
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModelsWithOffCatalogGoogle,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: "google-legacy")
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_model_detail_edit_offcatalog_light_xxl", function: function)
    }

    #if DEBUG
    @Test("model detail edit — debug mock search selected (light)")
    func modelDetailDebugSearch() async {
        await verifyModelDetailEdit(
            theme: .vellumLight, models: Self.sampleModelsWithDebugSearch, id: "debug-mock-search",
            name: "settings_model_detail_debug_search_light"
        )
    }
    #endif

    /// Drive the model-detail pane in edit mode over an arbitrary `models`
    /// fixture + row id — used by the web-search picker snapshots, which need
    /// rows (native / debug-backed) that aren't in the default `sampleModels`.
    private func verifyModelDetailEdit(
        theme: SuperTheme.Identifier,
        models: [SettingsViewModel.ModelRow],
        id: String,
        name: String,
        function: String = #function
    ) async {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: models,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: id)
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    @Test("personalization pane")
    func personalizationPane() async {
        await verify(theme: .vellumLight, pane: .personalization, name: "settings_personalization_light")
    }

    @Test("default verbosity pane")
    func verbosityPane() async {
        await verify(theme: .vellumLight, pane: .verbosity, name: "settings_verbosity_light")
    }

    @Test("appearance pane")
    func appearancePane() async {
        await verify(theme: .vellumLight, pane: .appearance, name: "settings_appearance_light")
    }

    // The merged Appearance pane owns the theme grid, so it carries the
    // full light/dark/sepia × default/XXL matrix per `Packages/Chat/AGENTS.md`.
    // The dark/sepia variants seed a matching `themeId` so the selected-card
    // border + halo render on a non-Light card too.

    @Test("appearance pane in dark")
    func appearancePaneDark() async {
        await verify(
            theme: .vellumDark, pane: .appearance, name: "settings_appearance_dark",
            settings: Self.settings(themeId: .vellumDark)
        )
    }

    @Test("dynamic type XXL on appearance pane")
    func appearancePaneXXL() async {
        let function = #function
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .appearance
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_appearance_light_xxl", function: function)
    }

    // With font-scale + Haptics at the top, the tail of the theme grid runs
    // off the bottom of the standard 874pt pane snapshots above — so the pane
    // needs a full-height render for the later families to get explicit
    // coverage. These use a tall fixed layout rather than the shared 874 frame
    // so the whole scroll content lands in one image. The `…Haptics…`
    // function and baseline names predate the reorder and are kept as-is —
    // baseline filenames embed the function name, so renaming would orphan
    // the recorded PNGs.
    @Test("appearance pane — full height shows the whole theme grid")
    func appearancePaneHapticsLight() {
        verifyTallAppearancePane(theme: .vellumLight, name: "settings_appearance_haptics_light")
    }

    @Test("appearance pane full height — whole theme grid in dark")
    func appearancePaneHapticsDark() {
        verifyTallAppearancePane(
            theme: .vellumDark, name: "settings_appearance_haptics_dark",
            settings: Self.settings(themeId: .vellumDark)
        )
    }

    @Test("tools pane")
    func toolsPane() async {
        await verify(theme: .vellumLight, pane: .tools, name: "settings_tools_light")
    }

    @Test("tools pane in dark")
    func toolsPaneDark() async {
        await verify(
            theme: .vellumDark, pane: .tools, name: "settings_tools_dark",
            settings: Self.settings(themeId: .vellumDark)
        )
    }

    @Test("dynamic type XXL on tools pane")
    func toolsPaneXXL() async {
        let function = #function
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .tools
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_tools_light_xxl", function: function)
    }

    @Test("compaction pane")
    func compactionPane() async {
        await verify(theme: .vellumLight, pane: .compaction, name: "settings_compaction_light")
    }

    // Search pane — the two key states are the cost gate ON (default) and
    // OFF, each across light / dark / sepia, plus an XXL fixed-chrome
    // sentinel (see the suite note: settings text scales with the in-app
    // font-scale slider, not OS Dynamic Type, so the XXL baseline is
    // intentionally byte-identical to `searchPaneOnLight` and a diff would
    // flag an accidental reintroduction of Dynamic Type scaling here).
    @Test("search pane, gate on, light")
    func searchPaneOnLight() async {
        await verify(theme: .vellumLight, pane: .search, name: "settings_search_on_light")
    }

    @Test("search pane, gate on, dark")
    func searchPaneOnDark() async {
        await verify(theme: .vellumDark, pane: .search, name: "settings_search_on_dark")
    }

    @Test("search pane, gate off, light")
    func searchPaneOffLight() async {
        await verify(
            theme: .vellumLight, pane: .search, name: "settings_search_off_light",
            settings: Self.settings(askBeforeSearching: false)
        )
    }

    @Test("search pane, gate off, dark")
    func searchPaneOffDark() async {
        await verify(
            theme: .vellumDark, pane: .search, name: "settings_search_off_dark",
            settings: Self.settings(askBeforeSearching: false)
        )
    }

    @Test("search pane, dynamic type XXL")
    func searchPaneXXL() async {
        let function = #function
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(settings: .default)
        let view = SettingsSheetSnapshotHarness(viewModel: viewModel, initialPane: .search)
            .superTheme(.make(.vellumLight))
            .dynamicTypeSize(.xxLarge)
            .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_search_on_light_xxl", function: function)
    }

    @Test("data pane — export idle")
    func dataPaneIdle() {
        verifyDataPane(theme: .vellumLight, phase: .idle, name: "settings_data_idle_light")
        verifyDataPane(theme: .vellumDark, phase: .idle, name: "settings_data_idle_dark")
    }

    /// Dynamic Type XXL sentinel for the label/status reflow column. Settings
    /// text is DT-inert (`typography.font(role)` with `relativeTo: nil`), so
    /// this is byte-identical to the default-DT idle baseline — a guard against
    /// accidentally reintroducing OS Dynamic Type scaling to settings chrome.
    @Test("data pane — export idle, Dynamic Type XXL")
    func dataPaneIdleXXL() {
        verifyDataPane(
            theme: .vellumLight,
            phase: .idle,
            name: "settings_data_idle_light_xxl",
            dynamicType: .xxLarge
        )
    }

    @Test("data pane — exporting")
    func dataPaneExporting() {
        verifyDataPane(theme: .vellumLight, phase: .exporting, name: "settings_data_exporting_light")
        verifyDataPane(theme: .vellumDark, phase: .exporting, name: "settings_data_exporting_dark")
    }

    // Note: the `.finished` phase no longer renders an in-pane row — it
    // auto-presents the system share sheet (out of scope for these content
    // snapshots), so there is no `dataPaneFinished` case.

    @Test("data pane — export failed")
    func dataPaneFailed() {
        let phase = ChatExportController.Phase.failed(message: "Could not write the export file.")
        verifyDataPane(theme: .vellumLight, phase: phase, name: "settings_data_failed_light")
        verifyDataPane(theme: .vellumDark, phase: phase, name: "settings_data_failed_dark")
    }

    /// Render the Data pane with the export controller forced into `phase`.
    private func verifyDataPane(
        theme: SuperTheme.Identifier,
        phase: ChatExportController.Phase,
        name: String,
        dynamicType: DynamicTypeSize = .large,
        function: String = #function
    ) {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(settings: .default, chatCount: 7)
        viewModel.exportController._setSnapshotPhase(phase)
        let view = SettingsSheetSnapshotHarness(viewModel: viewModel, initialPane: .data)
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    @Test("about pane")
    func aboutPane() async {
        await verify(theme: .vellumLight, pane: .about, name: "settings_about_light")
    }

    @Test("dynamic type XXL on root pane")
    func dynamicTypeXXL() async {
        let function = #function
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: .default,
            models: Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .root
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_root_light_xxl", function: function)
    }

    // The Settings sheet's slide-up entry transition is opacity-only with
    // Reduce Motion on (see `SettingsSheet.swift`). The steady-state first
    // frame for both transitions is identical, so a captured snapshot
    // wouldn't detect a regression in the reduced-motion branch even if we
    // recorded one — the same gap documented in
    // `MessageListSnapshotTests` and `SidebarDrawerSnapshotTests`.

    /// `ChatSettings.default` with `themeId` overridden — used by the
    /// appearance-pane variants so the grid's selected card matches the
    /// chrome theme under test.
    private static func settings(themeId: ChatSettings.ThemeID) -> ChatSettings {
        var settings = ChatSettings.default
        settings.themeId = themeId
        return settings
    }

    /// `ChatSettings.default` with the web-search cost gate overridden —
    /// used by the Search-pane variants to capture the toggle-off state.
    private static func settings(askBeforeSearching: Bool) -> ChatSettings {
        var settings = ChatSettings.default
        settings.askBeforeSearching = askBeforeSearching
        return settings
    }

    private func verify(
        theme: SuperTheme.Identifier,
        pane: SettingsSheet.Pane,
        name: String,
        settings: ChatSettings = .default,
        function: String = #function
    ) async {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: settings,
            models: Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: pane
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    /// Tall fixed layout so the full Look & Feel pane (font-scale card +
    /// Haptics toggle + theme grid) renders in one image — the standard 874pt
    /// frame clips the grid's later families off the bottom.
    private static let tallFrame = CGSize(width: 402, height: 1340)

    private func verifyTallAppearancePane(
        theme: SuperTheme.Identifier,
        name: String,
        settings: ChatSettings = .default,
        function: String = #function
    ) {
        let viewModel = makeViewModel()
        viewModel._setSnapshotState(
            settings: settings,
            models: Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(viewModel: viewModel, initialPane: .appearance)
            .superTheme(.make(theme))
            .frame(width: Self.tallFrame.width, height: Self.tallFrame.height)
        let failure = verifySnapshot(
            of: view,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.97,
                layout: .fixed(width: Self.tallFrame.width, height: Self.tallFrame.height)
            ),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    /// Compares (or records) `view` against the named baseline.
    ///
    /// Uses the same `precision` / `perceptualPrecision` budget as
    /// `ChatScreenSnapshotTests` so both snapshot suites share one comparison
    /// policy. The small tolerance absorbs the custom brand face's run-to-run
    /// glyph-edge anti-aliasing (which trips exact comparison at large Dynamic
    /// Type) while still failing on any real layout/text/color regression — a
    /// genuine change registers far above a ~1% / ~3% delta.
    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifySnapshot(
            of: view,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.97,
                layout: .fixed(width: Self.frame.width, height: Self.frame.height)
            ),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    private func makeViewModel(
        appleFoundationAvailability: AppleFoundationAvailability = .unavailable(.deviceNotEligible),
        audioSetup: ProviderAudioSetup? = nil
    ) -> SettingsViewModel {
        // Snapshots default to `.unavailable(.deviceNotEligible)` so the
        // host's real `SystemLanguageModel.default.availability` (which
        // varies between local dev and CI runners) never leaks into the
        // pixel-comparison. Tests that exercise AFM-specific rendering
        // pass an explicit availability. Same reasoning pins
        // `appleFoundationContextTokens` to a fixed value so the AFM read-only
        // Max-context row renders a stable number regardless of the host.
        SettingsViewModel(
            appInfo: Self.appInfo,
            settingRepository: NoopSettingRepository(),
            modelRepository: NoopModelRepository(),
            conversationRepository: NoopConversationRepository(),
            toolRegistry: ToolRegistry(),
            userPersonalizationReceiver: FakeUserPersonalizationReceiver(),
            autoCompactPolicyReceiver: FakeAutoCompactPolicyReceiver(),
            webSearchPolicyReceiver: FakeWebSearchPolicyReceiver(),
            appleFoundationAvailability: appleFoundationAvailability,
            appleFoundationContextTokens: 4_096,
            audioSetup: audioSetup
        )
    }
}

/// SwiftUI test harness — present the sheet in its open state on top of a
/// neutral background so the snapshot frames the chrome consistently. Uses
/// `SettingsSheet`'s internal `initialPane:` seam to render any sub-pane
/// without programmatically driving the navigation stack.
private struct SettingsSheetSnapshotHarness: View {
    let viewModel: SettingsViewModel
    let initialPane: SettingsSheet.Pane
    /// Forwarded to `SettingsSheet`'s internal test seam — only
    /// observed when `initialPane == .modelDetail(id: nil)`.
    var initialModelDetailSelection: SettingsModelDetailPane.InitialSelection = .custom
    /// Forwarded to `SettingsSheet`'s test seam for snapshotting the
    /// Max-Context inline-error state without driving a Save tap.
    var initialModelDetailContextWindowError: String?
    /// Forwarded to `SettingsSheet`'s test seam — seeds the create-mode
    /// API-key field so the key-gated rows (Model / Max context / Thinking /
    /// Web search) render without driving the SecureField.
    var initialModelDetailAPIKey: String?
    /// When `true`, render `initialPane` as the sheet's *modal root* (empty
    /// navigation path, `viewModel.rootPane` pre-seeded) — the close-✕ leading
    /// header state used by the composer's "Manage models…". When `false`
    /// (default), the pane is rendered *pushed* via the `initialPane:` seam,
    /// which shows the back chevron.
    var presentAsRoot = false

    @State private var presented = true
    @Environment(\.superTheme) private var theme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
            sheet
        }
        // Mirror the production composition root (`AppShell`), which builds
        // `.superTypography` from the persisted settings. Without this the
        // panes would render with the environment-default typography and a
        // future font-scale variant would silently snapshot the wrong scale.
        .superTypography(.make(viewModel.settings.typographyID, fontScale: viewModel.settings.fontScale))
    }

    @ViewBuilder
    private var sheet: some View {
        if presentAsRoot {
            // Use the *public* init with an empty navigation path so the leading
            // header renders the close-✕ (the composer's "Manage models…" entry
            // point). The caller seeds `viewModel.rootPane = initialPane` before
            // constructing the harness — mutating it here would write the model
            // during view-body evaluation.
            SettingsSheet(isPresented: $presented, viewModel: viewModel)
        } else {
            SettingsSheet(
                isPresented: $presented,
                viewModel: viewModel,
                initialPane: initialPane,
                initialModelDetailSelection: initialModelDetailSelection,
                initialModelDetailContextWindowError: initialModelDetailContextWindowError,
                initialModelDetailAPIKey: initialModelDetailAPIKey
            )
        }
    }
}

private struct NoopSettingRepository: SettingRepository {
    func get(_ key: String) async throws -> String? { nil }
    func set(_ key: String, value: String) async throws {}
    func delete(_ key: String) async throws {}
    func all() async throws -> [String: String] { [:] }
}

private struct NoopModelRepository: ModelConfigurationRepository {
    func all() async throws -> [ModelConfigurationRecord] { [] }
    func fetch(id: String) async throws -> ModelConfigurationRecord? { nil }
    func selected() async throws -> ModelConfigurationRecord? { nil }
    func save(_ record: ModelConfigurationRecord) async throws {}
    func insertIfEmpty(make: @Sendable () -> ModelConfigurationRecord) async throws -> ModelConfigurationRecord? { nil }
    func delete(id: String) async throws {}
    func setSelected(id: String) async throws {}
    func storeAPIKey(_ key: String, ref: String) async throws {}
    func loadAPIKey(ref: String) async throws -> String? { nil }
}

private struct NoopConversationRepository: ConversationRepository {
    func listActive() async throws -> [ConversationRecord] { [] }
    func listActiveRecent(limit: Int) async throws -> [ConversationRecord] { [] }
    func fetch(id: String) async throws -> ConversationRecord? { nil }
    func save(_ record: ConversationRecord) async throws {}
    func softDelete(id: String, at deletedAt: Date) async throws {}
    func hardDelete(id: String) async throws {}
}
#endif
