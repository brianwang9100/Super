#if DEBUG && canImport(UIKit)
import Core
import SwiftUI

#Preview("settings_root_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .root, theme: .vellumLight)
}

#Preview("settings_root_dark", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .root, theme: .vellumDark)
}

#Preview("settings_about_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .about, theme: .vellumLight)
}

#Preview("settings_compaction_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .compaction, theme: .vellumLight)
}

#Preview("settings_personalization_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .personalization, theme: .vellumLight)
}

#Preview("settings_verbosity_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .verbosity, theme: .vellumLight)
}

#Preview("settings_tools_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .tools, theme: .vellumLight)
}

#Preview("settings_tools_dark", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .tools, theme: .vellumDark, selectedTheme: .vellumDark)
}

#Preview("settings_search_on_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .search, theme: .vellumLight)
}

#Preview("settings_search_on_dark", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .search, theme: .vellumDark)
}

#Preview("settings_search_off_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .search, theme: .vellumLight, askBeforeSearching: false)
}

#Preview("settings_data_idle_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .data, theme: .vellumLight, exportPhase: .idle)
}

#Preview("settings_data_idle_dark", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .data, theme: .vellumDark, exportPhase: .idle)
}

#Preview("settings_data_failed_light", traits: .fixedLayout(width: 402, height: 874)) {
    PreviewSettingsPane(pane: .data, theme: .vellumLight, exportPhase: .failed(message: "Could not write the export file."))
}

#endif
