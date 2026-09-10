import Foundation
import Testing
@testable import Chat

@Suite("SettingsModelsPane title resolution")
@MainActor
struct SettingsModelsPaneTests {
    private func row(id: String, modelId: String) -> SettingsViewModel.ModelRow {
        SettingsViewModel.ModelRow(
            id: id, name: id, monogram: "M", endpoint: "",
            maxContextTokens: 1, isEnabled: true, modelId: modelId
        )
    }

    @Test("an explicit record id resolves to that row")
    func explicitRecordId() {
        let models = [row(id: "opus", modelId: "claude-opus-4-7"), row(id: "gpt", modelId: "gpt-5.5")]
        #expect(SettingsModelsPane.resolvedTitleRecordID(titleModelId: "gpt", in: models) == "gpt")
    }

    @Test("a legacy LLMModel.id resolves to its row's record id")
    func legacyModelId() {
        let models = [row(id: "opus", modelId: "claude-opus-4-7"), row(id: "gpt", modelId: "gpt-5.5")]
        #expect(SettingsModelsPane.resolvedTitleRecordID(titleModelId: "claude-opus-4-7", in: models) == "opus")
    }

    @Test("two rows sharing a modelId resolve to a single record id, and each record id resolves to itself")
    func sharedModelIdDoesNotDoubleResolve() {
        // Legacy shared model IDs resolve deterministically; record IDs remain unambiguous.
        let models = [row(id: "debug-canned", modelId: "debug-default"),
                      row(id: "debug-mock-search", modelId: "debug-default")]
        #expect(SettingsModelsPane.resolvedTitleRecordID(titleModelId: "debug-default", in: models) == "debug-canned")
        #expect(SettingsModelsPane.resolvedTitleRecordID(titleModelId: "debug-canned", in: models) == "debug-canned")
        #expect(SettingsModelsPane.resolvedTitleRecordID(titleModelId: "debug-mock-search", in: models) == "debug-mock-search")
    }

    @Test("an unresolvable id (deleted model) resolves to nil")
    func deletedModel() {
        let models = [row(id: "opus", modelId: "claude-opus-4-7")]
        #expect(SettingsModelsPane.resolvedTitleRecordID(titleModelId: "gone", in: models) == nil)
    }
}
