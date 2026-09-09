#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

// Capture sheet content; native presentation chrome is outside this harness.
// Retain remaining cases until their SettingsPanePreviews replacements are verified.
// Settings text tracks the app slider; XXL companions check fixed chrome stability.
@Suite("SettingsSheet snapshots", .serialized)
@MainActor
struct SettingsSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }
    private static let frame = CGSize(width: 402, height: 874)

    private static let appInfo = SuperAppInfo(bundleName: "Super", version: "0.3.1", build: "1")

    private static let sampleModels: [SettingsViewModel.ModelRow] = [
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
    private static let sampleModelsWithDebugSearch: [SettingsViewModel.ModelRow] = sampleModels + [
        .init(
            id: "debug-mock-search", name: "Debug (mock search)", monogram: "DB",
            endpoint: "", maxContextTokens: DebugLLMProvider.maxContextTokens, isEnabled: true,
            kind: .debug, baseURL: nil, modelId: DebugLLMProvider.modelID,
            supportsThinking: true, hasAPIKey: false, searchBackend: "debug"
        ),
    ]
    #endif

    private static let openAIUnlockedFetchedModels = [
        "openai": LLMProviderCatalog.reconcile(
            providerID: "openai",
            fetchedModelIDs: ["gpt-5.5", "gpt-5.4-mini", "gpt-6-preview"]
        ),
    ]

    private static let sampleTools: [SettingsViewModel.ToolRow] = [
        .init(id: "bible.annotate", name: "Bible annotations", summary: "Writes a markdown study summary for a passage.", isEnabled: true),
        .init(id: "time.now", name: "Current time", summary: "Reports the current date and time.", isEnabled: false),
        // The gear is visible only for an enabled, configurable tool.
        .init(
            id: MemoryTool.toolID,
            name: "Memory",
            summary: "Remembers your preferences across conversations.",
            isEnabled: true,
            configPane: .memory
        ),
    ]

    @Test("models pane populated")
    func modelsPopulated() async {
        await verify(theme: .vellumLight, pane: .models, name: "settings_models_light")
    }

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

    // A collapsed snapshot cannot inspect the expanded provider menu lock state.
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
            // Seed a key so the gated Model row and its fallback note are visible.
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

    @Test("model detail disables Save and Delete during a shared mutation")
    func modelDetailBusy() async {
        await verifyBusyModelDetail(theme: .vellumLight, name: "settings_model_detail_busy_light")
    }

    @Test("model detail disables Save and Delete during a shared mutation (dark)")
    func modelDetailBusyDark() async {
        await verifyBusyModelDetail(theme: .vellumDark, name: "settings_model_detail_busy_dark")
    }

    private func verifyBusyModelDetail(
        theme: SuperTheme.Identifier, name: String, function: String = #function
    ) async {
        let gate = SnapshotModelMutationGate()
        let viewModel = makeViewModel(modelRepository: NoopModelRepository(fetchGate: gate))
        viewModel._setSnapshotState(
            settings: .default, models: Self.sampleModels, tools: Self.sampleTools, chatCount: 7
        )
        let save = Task {
            await viewModel.updateModel(
                id: "opus", name: "Pending", baseURL: nil, modelId: "claude-opus-4-7",
                apiKey: "", supportsThinking: true, maxContextTokens: 200_000
            )
        }
        await gate.waitUntilEntered()
        #expect(viewModel.isModelMutationInFlight(id: "opus"))
        let view = SettingsSheetSnapshotHarness(viewModel: viewModel, initialPane: .modelDetail(id: "opus"))
            .superTheme(.make(theme))
            .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
        await gate.release()
        _ = await save.value
    }

    @Test("model detail seeded form for Apple Foundation row")
    func modelDetailAppleFoundation() async {
        await verifyAppleFoundation(theme: .vellumLight, name: "settings_model_detail_afm_light")
    }

    @Test("model detail seeded form for Apple Foundation row (dark)")
    func modelDetailAppleFoundationDark() async {
        await verifyAppleFoundation(theme: .vellumDark, name: "settings_model_detail_afm_dark")
    }

    @Test("dynamic type XXL on Apple Foundation model detail pane")
    func modelDetailAppleFoundationXXL() async {
        await verifyAppleFoundationXXL(theme: .vellumLight, name: "settings_model_detail_afm_light_xxl")
    }

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

    @Test("model detail seeded form (edit flow) in dark")
    func modelDetailEditDark() async {
        await verify(theme: .vellumDark, pane: .modelDetail(id: "opus"), name: "settings_model_detail_edit_dark")
    }

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

    // Keep XXL and tall-dark cases until their Argos replacements are verified.

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

    // Legacy Haptics function names are embedded in baseline paths; renaming would orphan PNGs.
    @Test("appearance pane full height — whole theme grid in dark")
    func appearancePaneHapticsDark() {
        verifyTallAppearancePane(
            theme: .vellumDark, name: "settings_appearance_haptics_dark",
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
        verifyDataPane(theme: .vellumDark, phase: .exporting, name: "settings_data_exporting_dark")
    }

    // Finished export presents the system share sheet, outside these content snapshots.

    @Test("data pane — export failed")
    func dataPaneFailed() {
        let phase = ChatExportController.Phase.failed(message: "Could not write the export file.")
        verifyDataPane(theme: .vellumDark, phase: phase, name: "settings_data_failed_dark")
    }

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

    private static func settings(themeId: ChatSettings.ThemeID) -> ChatSettings {
        var settings = ChatSettings.default
        settings.themeId = themeId
        return settings
    }

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

    /// The standard-height canvas clips later theme families; capture the whole grid here.
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
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.97,
                layout: .fixed(width: Self.tallFrame.width, height: Self.tallFrame.height)
            ),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    /// Scope tolerance to cross-runner font-edge antialiasing.
    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.97,
                layout: .fixed(width: Self.frame.width, height: Self.frame.height)
            ),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    private func makeViewModel(
        appleFoundationAvailability: AppleFoundationAvailability = .unavailable(.deviceNotEligible),
        audioSetup: ProviderAudioSetup? = nil,
        modelRepository: any ModelConfigurationRepository = NoopModelRepository()
    ) -> SettingsViewModel {
        // Fix availability and context size so host model state cannot change rendered values.
        SettingsViewModel(
            appInfo: Self.appInfo,
            settingRepository: NoopSettingRepository(),
            modelRepository: modelRepository,
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

private struct SettingsSheetSnapshotHarness: View {
    let viewModel: SettingsViewModel
    let initialPane: SettingsSheet.Pane
    /// Only applies to model-detail creation.
    var initialModelDetailSelection: SettingsModelDetailPane.InitialSelection = .custom
    var initialModelDetailContextWindowError: String?
    var initialModelDetailAPIKey: String?
    /// Root presentation uses close; a pushed pane uses back. Seed rootPane before rendering.
    var presentAsRoot = false

    @State private var presented = true
    @Environment(\.superTheme) private var theme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
            sheet
        }
        // Match persisted typography from the composition root instead of environment defaults.
        .superTypography(.make(viewModel.settings.typographyID, fontScale: viewModel.settings.fontScale))
    }

    @ViewBuilder
    private var sheet: some View {
        if presentAsRoot {
            // Seed rootPane before construction to avoid mutating the model during body evaluation.
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

private actor SnapshotModelMutationGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct NoopModelRepository: ModelConfigurationRepository {
    var fetchGate: SnapshotModelMutationGate?
    func all() async throws -> [ModelConfigurationRecord] { [] }
    func fetch(id: String) async throws -> ModelConfigurationRecord? {
        await fetchGate?.suspend()
        return nil
    }
    func selected() async throws -> ModelConfigurationRecord? { nil }
    func save(_ record: ModelConfigurationRecord) async throws {}
    func update(_ record: ModelConfigurationRecord, expectedAPIKeyRef: String?) async throws {}
    func insertIfEmpty(make: @Sendable () -> ModelConfigurationRecord) async throws -> ModelConfigurationRecord? { nil }
    func delete(id: String) async throws {}
    func setSelected(id: String) async throws {}
    func storeAPIKey(_ key: String, ref: String) async throws {}
    func loadAPIKey(ref: String) async throws -> String? { nil }
    func deleteAPIKey(ref: String) async throws {}
    func deleteAPIKeyIfUnreferenced(ref: String) async throws {}
    func registerStagedAPIKey(ref: String) async throws {}
    func discardStagedAPIKey(ref: String) async throws {}
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
