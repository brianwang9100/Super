#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Pixel-stable snapshots of `SettingsSheet` across themes and panes.
/// Each scenario embeds the sheet inside a fixed-size container that
/// mimics the iPhone 17 chat surface so the bottom-sheet inset + scrim
/// composition matches what ships in production.
@Suite("SettingsSheet snapshots", .serialized)
@MainActor
struct SettingsSheetSnapshotTests {
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

    private static let sampleTools: [SettingsViewModel.ToolRow] = [
        .init(id: "time.now", name: "Current time", summary: "Returns the current local time in ISO-8601.", isEnabled: true),
        // Memory is enabled in the snapshot so the gear affordance
        // (visible only when both enabled AND configurable) renders;
        // disabling it would hide the very thing this snapshot covers.
        .init(
            id: MemoryTool.toolID,
            name: "Memory",
            summary: "Lets me remember preferences across conversations.",
            isEnabled: true,
            configPane: .memory
        ),
    ]

    @Test("root pane in light")
    func rootLight() async {
        await verify(theme: .light, pane: .root, name: "settings_root_light")
    }

    @Test("root pane in dark")
    func rootDark() async {
        await verify(theme: .dark, pane: .root, name: "settings_root_dark")
    }

    @Test("root pane in sepia")
    func rootSepia() async {
        await verify(theme: .sepia, pane: .root, name: "settings_root_sepia")
    }

    @Test("models pane populated")
    func modelsPopulated() async {
        await verify(theme: .light, pane: .models, name: "settings_models_light")
    }

    @Test("models pane with AFM row when AFM is available")
    func modelsPaneWithAFMAvailable() async {
        await verifyModelsPaneWithAFM(
            theme: .light,
            availability: .available,
            name: "settings_models_afm_available_light"
        )
    }

    @Test("models pane with AFM row when AFM is available (dark)")
    func modelsPaneWithAFMAvailableDark() async {
        await verifyModelsPaneWithAFM(
            theme: .dark,
            availability: .available,
            name: "settings_models_afm_available_dark"
        )
    }

    @Test("models pane with AFM row when AFM is unavailable (modelNotReady)")
    func modelsPaneWithAFMModelNotReady() async {
        await verifyModelsPaneWithAFM(
            theme: .light,
            availability: .unavailable(.modelNotReady),
            name: "settings_models_afm_model_not_ready_light"
        )
    }

    @Test("models pane with AFM row when AFM is unavailable (deviceNotEligible)")
    func modelsPaneWithAFMDeviceNotEligible() async {
        await verifyModelsPaneWithAFM(
            theme: .light,
            availability: .unavailable(.deviceNotEligible),
            name: "settings_models_afm_device_not_eligible_light"
        )
    }

    @Test("models pane with AFM row when AFM is unavailable (modelNotReady, dark)")
    func modelsPaneWithAFMModelNotReadyDark() async {
        await verifyModelsPaneWithAFM(
            theme: .dark,
            availability: .unavailable(.modelNotReady),
            name: "settings_models_afm_model_not_ready_dark"
        )
    }

    @Test("models pane with AFM row when AFM is unavailable (appleIntelligenceNotEnabled)")
    func modelsPaneWithAFMAppleIntelligenceNotEnabled() async {
        await verifyModelsPaneWithAFM(
            theme: .light,
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
            theme: .light,
            availability: .available,
            name: "settings_models_afm_available_light_xxl",
            dynamicType: .xxLarge
        )
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
    // the visible-field set the provider's catalog entry dictates:
    // Apple hides URL/Name/Key/Thinking; OpenAI/Anthropic/Google/xAI
    // hide URL+Name and show Key + (Thinking iff the default model
    // supports it); Custom shows every field.

    @Test("model detail create flow — Apple Intelligence selected")
    func modelDetailProviderApple() async {
        await verifyCreateWithProvider(
            theme: .light,
            selection: .apple,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_apple_light"
        )
    }

    @Test("model detail create flow — Apple Intelligence selected (dark)")
    func modelDetailProviderAppleDark() async {
        await verifyCreateWithProvider(
            theme: .dark,
            selection: .apple,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_apple_dark"
        )
    }

    @Test("model detail create flow — OpenAI selected")
    func modelDetailProviderOpenAI() async {
        await verifyCreateWithProvider(
            theme: .light,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_openai_light"
        )
    }

    @Test("model detail create flow — OpenAI selected (dark)")
    func modelDetailProviderOpenAIDark() async {
        await verifyCreateWithProvider(
            theme: .dark,
            selection: .openAI,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_openai_dark"
        )
    }

    @Test("model detail create flow — Anthropic selected")
    func modelDetailProviderAnthropic() async {
        await verifyCreateWithProvider(
            theme: .light,
            selection: .anthropic,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_anthropic_light"
        )
    }

    @Test("model detail create flow — Anthropic selected (dark)")
    func modelDetailProviderAnthropicDark() async {
        await verifyCreateWithProvider(
            theme: .dark,
            selection: .anthropic,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_anthropic_dark"
        )
    }

    @Test("model detail create flow — Google selected")
    func modelDetailProviderGoogle() async {
        await verifyCreateWithProvider(
            theme: .light,
            selection: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_google_light"
        )
    }

    @Test("model detail create flow — Google selected (dark)")
    func modelDetailProviderGoogleDark() async {
        await verifyCreateWithProvider(
            theme: .dark,
            selection: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_google_dark"
        )
    }

    @Test("model detail create flow — xAI selected")
    func modelDetailProviderXAI() async {
        await verifyCreateWithProvider(
            theme: .light,
            selection: .xai,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_xai_light"
        )
    }

    @Test("model detail create flow — xAI selected (dark)")
    func modelDetailProviderXAIDark() async {
        await verifyCreateWithProvider(
            theme: .dark,
            selection: .xai,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_xai_dark"
        )
    }

    @Test("model detail create flow — Custom selected (all fields visible)")
    func modelDetailProviderCustom() async {
        await verifyCreateWithProvider(
            theme: .light,
            selection: .custom,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_custom_light"
        )
    }

    @Test("model detail create flow — Custom selected (dark)")
    func modelDetailProviderCustomDark() async {
        await verifyCreateWithProvider(
            theme: .dark,
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
            theme: .light,
            selection: .custom,
            availability: .unavailable(.appleIntelligenceNotEnabled),
            existingAppleFoundation: false,
            name: "settings_model_detail_apple_disabled_light"
        )
    }

    @Test("model detail create flow — Apple provider locked (dark)")
    func modelDetailProviderAppleDisabledDark() async {
        await verifyCreateWithProvider(
            theme: .dark,
            selection: .custom,
            availability: .unavailable(.appleIntelligenceNotEnabled),
            existingAppleFoundation: false,
            name: "settings_model_detail_apple_disabled_dark"
        )
    }

    // Sepia anchor for the picker UI per Chat AGENTS.md
    // (light/dark/sepia × default × Dynamic Type XXL matrix). Picks
    // Custom because it exercises the widest set of form rows the
    // theme's `inkFaint`/`borderFaint`/`ink` tokens render across; a
    // sepia regression on the picker chevron or field caps would
    // show up here.
    @Test("model detail create flow — Custom selected (sepia)")
    func modelDetailProviderCustomSepia() async {
        await verifyCreateWithProvider(
            theme: .sepia,
            selection: .custom,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_custom_sepia"
        )
    }

    // Inline-error state for the Max Context field after the user
    // typed an over-cap value and tapped Save. Uses the test seam
    // `initialModelDetailContextWindowError` to pre-set the error
    // without simulating a Save tap. Per AGENTS.md §Testing.3 —
    // SwiftUI views ship snapshots for their error state.
    @Test("model detail create flow — context-window over-cap error (light)")
    func modelDetailProviderContextWindowError() async {
        await verifyCreateWithProvider(
            theme: .light,
            selection: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_context_error_light",
            contextWindowError: "Maximum context for this model is 1,000,000 tokens."
        )
    }

    @Test("model detail create flow — context-window over-cap error (dark)")
    func modelDetailProviderContextWindowErrorDark() async {
        await verifyCreateWithProvider(
            theme: .dark,
            selection: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_provider_context_error_dark",
            contextWindowError: "Maximum context for this model is 1,000,000 tokens."
        )
    }

    private func verifyCreateWithProvider(
        theme: SuperTheme.Identifier,
        selection: SettingsModelDetailPane.InitialSelection,
        availability: AppleFoundationAvailability,
        existingAppleFoundation: Bool,
        name: String,
        contextWindowError: String? = nil,
        function: String = #function
    ) async {
        let viewModel = makeViewModel(appleFoundationAvailability: availability)
        viewModel._setSnapshotState(
            settings: .default,
            models: existingAppleFoundation
                ? Self.sampleModelsWithAppleFoundation
                : Self.sampleModels,
            tools: Self.sampleTools,
            chatCount: 7
        )
        let view = SettingsSheetSnapshotHarness(
            viewModel: viewModel,
            initialPane: .modelDetail(id: nil),
            initialModelDetailSelection: selection,
            initialModelDetailContextWindowError: contextWindowError
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    @Test("model detail seeded form (edit flow)")
    func modelDetailEdit() async {
        await verify(theme: .light, pane: .modelDetail(id: "opus"), name: "settings_model_detail_edit_light")
    }

    // Locks in the `baseURL == nil` init path introduced by the
    // provider-kind discriminator work: `_baseURLText` falls back
    // to the placeholder default when the row's URL is nil.
    @Test("model detail seeded form for Apple Foundation row")
    func modelDetailAppleFoundation() async {
        await verifyAppleFoundation(theme: .light, name: "settings_model_detail_afm_light")
    }

    // Dark companion per AGENTS.md §Testing.3.
    @Test("model detail seeded form for Apple Foundation row (dark)")
    func modelDetailAppleFoundationDark() async {
        await verifyAppleFoundation(theme: .dark, name: "settings_model_detail_afm_dark")
    }

    // Dynamic Type XXL companion per AGENTS.md §Testing.3.
    @Test("dynamic type XXL on Apple Foundation model detail pane")
    func modelDetailAppleFoundationXXL() async {
        await verifyAppleFoundationXXL(theme: .light, name: "settings_model_detail_afm_light_xxl")
    }

    // Dark + XXL cell to fill the `light/dark/sepia × default/Dynamic
    // Type XXL` matrix called out in `Packages/Chat/CLAUDE.md`.
    @Test("dynamic type XXL on Apple Foundation model detail pane (dark)")
    func modelDetailAppleFoundationXXLDark() async {
        await verifyAppleFoundationXXL(theme: .dark, name: "settings_model_detail_afm_dark_xxl")
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
        await verify(theme: .dark, pane: .modelDetail(id: "opus"), name: "settings_model_detail_edit_dark")
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
        .superTheme(.make(.light))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_model_detail_edit_light_xxl", function: function)
    }

    @Test("personalization pane")
    func personalizationPane() async {
        await verify(theme: .light, pane: .personalization, name: "settings_personalization_light")
    }

    @Test("default verbosity pane")
    func verbosityPane() async {
        await verify(theme: .light, pane: .verbosity, name: "settings_verbosity_light")
    }

    @Test("appearance pane")
    func appearancePane() async {
        await verify(theme: .light, pane: .appearance, name: "settings_appearance_light")
    }

    // The merged Appearance pane owns the theme grid, so it carries the
    // full light/dark/sepia × default/XXL matrix per `Packages/Chat/CLAUDE.md`.
    // The dark/sepia variants seed a matching `themeId` so the selected-card
    // border + halo render on a non-Light card too.

    @Test("appearance pane in dark")
    func appearancePaneDark() async {
        await verify(
            theme: .dark, pane: .appearance, name: "settings_appearance_dark",
            settings: Self.settings(themeId: .dark)
        )
    }

    @Test("appearance pane in sepia")
    func appearancePaneSepia() async {
        await verify(
            theme: .sepia, pane: .appearance, name: "settings_appearance_sepia",
            settings: Self.settings(themeId: .sepia)
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
        .superTheme(.make(.light))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "settings_appearance_light_xxl", function: function)
    }

    @Test("tools pane")
    func toolsPane() async {
        await verify(theme: .light, pane: .tools, name: "settings_tools_light")
    }

    @Test("compaction pane")
    func compactionPane() async {
        await verify(theme: .light, pane: .compaction, name: "settings_compaction_light")
    }

    @Test("data pane")
    func dataPane() async {
        await verify(theme: .light, pane: .data, name: "settings_data_light")
    }

    @Test("about pane")
    func aboutPane() async {
        await verify(theme: .light, pane: .about, name: "settings_about_light")
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
        .superTheme(.make(.light))
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

    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    private func makeViewModel(
        appleFoundationAvailability: AppleFoundationAvailability = .unavailable(.deviceNotEligible)
    ) -> SettingsViewModel {
        // Snapshots default to `.unavailable(.deviceNotEligible)` so the
        // host's real `SystemLanguageModel.default.availability` (which
        // varies between local dev and CI runners) never leaks into the
        // pixel-comparison. Tests that exercise AFM-specific rendering
        // pass an explicit availability.
        SettingsViewModel(
            accountEmail: "brianwang9100@gmail.com",
            appInfo: Self.appInfo,
            settingRepository: NoopSettingRepository(),
            modelRepository: NoopModelRepository(),
            conversationRepository: NoopConversationRepository(),
            toolRegistry: ToolRegistry(),
            userPersonalizationReceiver: FakeUserPersonalizationReceiver(),
            autoCompactPolicyReceiver: FakeAutoCompactPolicyReceiver(),
            appleFoundationAvailability: appleFoundationAvailability
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

    @State private var presented = true
    @Environment(\.superTheme) private var theme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
            SettingsSheet(
                isPresented: $presented,
                viewModel: viewModel,
                initialPane: initialPane,
                initialModelDetailSelection: initialModelDetailSelection,
                initialModelDetailContextWindowError: initialModelDetailContextWindowError
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
    func fetch(id: String) async throws -> ConversationRecord? { nil }
    func save(_ record: ConversationRecord) async throws {}
    func softDelete(id: String, at deletedAt: Date) async throws {}
    func hardDelete(id: String) async throws {}
}
#endif
