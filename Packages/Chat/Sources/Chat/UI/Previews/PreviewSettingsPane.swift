#if DEBUG && canImport(UIKit)
import Core
import SwiftUI

struct PreviewSettingsPane: View {
    let theme: SuperTheme.Identifier
    let height: CGFloat
    let pane: SettingsSheet.Pane
    @State private var viewModel: SettingsViewModel
    @State private var presented = true

    init(
        pane: SettingsSheet.Pane,
        theme: SuperTheme.Identifier,
        height: CGFloat = 874,
        selectedTheme: ChatSettings.ThemeID = .vellumLight,
        askBeforeSearching: Bool = true,
        exportPhase: ChatExportController.Phase? = nil
    ) {
        self.height = height
        self.pane = pane
        self.theme = theme
        var settings = ChatSettings.default
        settings.themeId = selectedTheme
        settings.askBeforeSearching = askBeforeSearching
        let model = SettingsViewModel(
            appInfo: .init(bundleName: "Super", version: "0.3.1", build: "1"),
            settingRepository: PreviewSettingRepository(),
            modelRepository: PreviewModelRepository(),
            conversationRepository: PreviewConversationRepository(),
            toolRegistry: ToolRegistry(),
            userPersonalizationReceiver: PreviewSettingsReceiver(),
            autoCompactPolicyReceiver: PreviewSettingsReceiver(),
            webSearchPolicyReceiver: PreviewSettingsReceiver(),
            appleFoundationAvailability: .unavailable(.deviceNotEligible),
            appleFoundationContextTokens: 4_096
        )
        // The data pane's original fixture has no model/tool rows. All others
        // use the same fixed inventory; preloading also suppresses async load().
        model._setSnapshotState(
            settings: settings,
            models: exportPhase == nil ? Self.sampleModels : [],
            tools: exportPhase == nil ? Self.sampleTools : [],
            chatCount: 7
        )
        if let exportPhase { model.exportController._setSnapshotPhase(exportPhase) }
        _viewModel = State(initialValue: model)
    }

    var body: some View {
        Core.registerBundledFonts()
        return ZStack {
            SuperTheme.make(theme).background.ignoresSafeArea()
            SettingsSheet(isPresented: $presented, viewModel: viewModel, initialPane: pane)
        }
        .superTheme(.make(theme))
        .superTypography(.make(viewModel.settings.typographyID, fontScale: viewModel.settings.fontScale))
        .dynamicTypeSize(.large)
        .frame(width: 402, height: height)
    }

    private static let sampleModels: [SettingsViewModel.ModelRow] = [
        // Match the existing-key placeholder in the model-edit fixture.
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

    private static let sampleTools: [SettingsViewModel.ToolRow] = [
        .init(id: "bible.annotate", name: "Bible annotations", summary: "Writes a markdown study summary for a passage.", isEnabled: true),
        // Include an off toggle while retaining the root pane's enabled count.
        .init(id: "time.now", name: "Current time", summary: "Reports the current date and time.", isEnabled: false),
        // Enable configurable memory so its gear affordance appears.
        .init(
            id: MemoryTool.toolID,
            name: "Memory",
            summary: "Remembers your preferences across conversations.",
            isEnabled: true,
            configPane: .memory
        ),
    ]

}

private struct PreviewSettingRepository: SettingRepository {
    func get(_ key: String) async throws -> String? { nil }
    func set(_ key: String, value: String) async throws {}
    func delete(_ key: String) async throws {}
    func all() async throws -> [String: String] { [:] }
}

private struct PreviewModelRepository: ModelConfigurationRepository {
    func all() async throws -> [ModelConfigurationRecord] { [] }
    func fetch(id: String) async throws -> ModelConfigurationRecord? { nil }
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

private struct PreviewConversationRepository: ConversationRepository {
    func listActive() async throws -> [ConversationRecord] { [] }
    func listActiveRecent(limit: Int) async throws -> [ConversationRecord] { [] }
    func fetch(id: String) async throws -> ConversationRecord? { nil }
    func save(_ record: ConversationRecord) async throws {}
    func softDelete(id: String, at deletedAt: Date) async throws {}
    func hardDelete(id: String) async throws {}
}

private struct PreviewSettingsReceiver: UserPersonalizationReceiver, AutoCompactPolicyReceiver, WebSearchPolicyReceiver {
    func setUserPersonalization(_ value: String) async {}
    func setAutoCompactPolicy(enabled: Bool, threshold: Double) async {}
    func setAskBeforeSearching(_ enabled: Bool) async {}
}
#endif
