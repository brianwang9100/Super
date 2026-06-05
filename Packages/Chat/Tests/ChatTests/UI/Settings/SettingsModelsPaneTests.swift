import Foundation
import Testing
@testable import Chat

/// Tests for `SettingsModelsPane.resolvedTitleRecordID` — the title-summarizer
/// checkmark resolution. The picker highlights a row by its unique record id,
/// with a back-compat branch for a legacy persisted `LLMModel.id`.
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
        // Upgraded install: titleModelId still holds the upstream model string.
        let models = [row(id: "opus", modelId: "claude-opus-4-7"), row(id: "gpt", modelId: "gpt-5.5")]
        #expect(SettingsModelsPane.resolvedTitleRecordID(titleModelId: "claude-opus-4-7", in: models) == "opus")
    }

    @Test("two rows sharing a modelId resolve to a single record id, and each record id resolves to itself")
    func sharedModelIdDoesNotDoubleResolve() {
        // The original bug, on the resolution side: a shared modelId must not
        // identify two rows. A legacy value maps to the first deterministically;
        // each record id still resolves to exactly its own row.
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
