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
            theme: .light,
            name: "settings_models_debug_light"
        )
    }

    @Test("models pane with debug provider row (dark)")
    func modelsPaneWithDebugDark() async {
        await verifyModelsPaneWithDebug(
            theme: .dark,
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

    @Test("model detail empty form (create flow)")
    func modelDetailEmpty() async {
        await verify(theme: .light, pane: .modelDetail(id: nil), name: "settings_model_detail_new_light")
    }

    @Test("model detail create flow with Google preset prefilled")
    func modelDetailGooglePreset() async {
        await verifyCreateWithPreset(
            theme: .light,
            preset: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_google_preset_light"
        )
    }

    @Test("model detail create flow with Google preset prefilled (dark)")
    func modelDetailGooglePresetDark() async {
        await verifyCreateWithPreset(
            theme: .dark,
            preset: .google,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_google_preset_dark"
        )
    }

    // Apple Intelligence preset prefilled — the pill is enabled (no
    // existing AFM row + AFM available). Distinct from the
    // AFM-edit-flow snapshot (`modelDetailAppleFoundation`) because
    // that test seeds from an existing row; this one tests the create
    // path where the preset drives the prefill.
    @Test("model detail create flow with Apple preset prefilled")
    func modelDetailApplePreset() async {
        await verifyCreateWithPreset(
            theme: .light,
            preset: .appleFoundation,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_apple_preset_light"
        )
    }

    @Test("model detail create flow with Apple preset prefilled (dark)")
    func modelDetailApplePresetDark() async {
        await verifyCreateWithPreset(
            theme: .dark,
            preset: .appleFoundation,
            availability: .available,
            existingAppleFoundation: false,
            name: "settings_model_detail_apple_preset_dark"
        )
    }

    // The disabled-Apple-pill state: AFM is unavailable so the Apple
    // pill is non-interactive. Custom preset stays selected. Anchors
    // the inkFaint foreground + disabled visual treatment introduced
    // by Phase 6b.
    @Test("model detail create flow with Apple preset disabled (AFM unavailable)")
    func modelDetailApplePresetDisabled() async {
        await verifyCreateWithPreset(
            theme: .light,
            preset: .custom,
            availability: .unavailable(.appleIntelligenceNotEnabled),
            existingAppleFoundation: false,
            name: "settings_model_detail_apple_disabled_light"
        )
    }

    // Dark companion for the disabled-Apple-pill state — the inkFaint
    // foreground is the most colour-scheme-sensitive piece of the
    // preset picker so we pin it across light + dark.
    @Test("model detail create flow with Apple preset disabled (dark)")
    func modelDetailApplePresetDisabledDark() async {
        await verifyCreateWithPreset(
            theme: .dark,
            preset: .custom,
            availability: .unavailable(.appleIntelligenceNotEnabled),
            existingAppleFoundation: false,
            name: "settings_model_detail_apple_disabled_dark"
        )
    }

    private func verifyCreateWithPreset(
        theme: SuperTheme.Identifier,
        preset: SettingsModelDetailPane.Preset,
        availability: AppleFoundationAvailability,
        existingAppleFoundation: Bool,
        name: String,
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
            initialModelDetailPreset: preset
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
    var initialModelDetailPreset: SettingsModelDetailPane.Preset = .custom

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
                initialModelDetailPreset: initialModelDetailPreset
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
