import Foundation
import Testing
@testable import Chat

/// Tests for `SettingsModelDetailPane.Preset.defaults` — the pure
/// helper the Add-Model preset picker uses to seed the form's @State.
/// Snapshot tests anchor the rendered result; these tests pin the
/// exact field values so a refactor of the picker UI can't silently
/// change what gets persisted on Save without also breaking these.
@Suite("SettingsModelDetailPane preset defaults")
struct SettingsModelDetailPanePresetTests {
    @Test("Apple Intelligence preset seeds AFM-shaped fields")
    func applePresetDefaults() {
        let defaults = SettingsModelDetailPane.Preset.appleFoundation.defaults
        #expect(defaults.name == "Apple Intelligence")
        #expect(defaults.modelId == "system-default")
        #expect(defaults.maxContextText == "4096")
        #expect(defaults.supportsThinking == false)
        // baseURL is irrelevant for AFM (the field isn't rendered) but
        // we still seed empty so toggling back to Google/Custom doesn't
        // inherit a stale value.
        #expect(defaults.baseURLText == "")
    }

    @Test("Google preset seeds Gemini's OpenAI-compatible endpoint")
    func googlePresetDefaults() {
        let defaults = SettingsModelDetailPane.Preset.google.defaults
        #expect(defaults.name == "Gemini 2.5 Pro")
        #expect(defaults.baseURLText == "https://generativelanguage.googleapis.com/v1beta/openai/")
        #expect(defaults.modelId == "gemini-2.5-pro")
        #expect(defaults.maxContextText == "1000000")
        // Gemini 2.5 Pro supports thinking; the toggle is prefilled so
        // the user doesn't have to discover the flag.
        #expect(defaults.supportsThinking == true)
    }

    @Test("Custom preset seeds OpenAI's defaults with blank name/key")
    func customPresetDefaults() {
        let defaults = SettingsModelDetailPane.Preset.custom.defaults
        #expect(defaults.name == "")
        #expect(defaults.baseURLText == "https://api.openai.com/v1")
        #expect(defaults.modelId == "")
        #expect(defaults.maxContextText == "200000")
        #expect(defaults.supportsThinking == false)
    }

    @Test("All preset cases have a non-empty label")
    func presetLabelsAreNonEmpty() {
        for preset in SettingsModelDetailPane.Preset.allCases {
            #expect(!preset.label.isEmpty, "Preset \(preset) must have a label")
        }
    }
}
