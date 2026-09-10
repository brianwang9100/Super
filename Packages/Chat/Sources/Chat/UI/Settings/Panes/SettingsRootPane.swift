import Core
import SwiftUI

struct SettingsRootPane: View {
    let viewModel: SettingsViewModel

    @Environment(\.appletSettingsContributions) private var appletContributions

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup {
                SettingsRow(
                    icon: AnyView(ModelsIcon()),
                    label: "Models",
                    value: "\(viewModel.models.count) configured",
                    action: { viewModel.openPane(.models) }
                )
                SettingsRow(
                    icon: AnyView(ThemeIcon()),
                    label: "Look & Feel",
                    value: themeName,
                    borderBottom: false,
                    action: { viewModel.openPane(.appearance) }
                )
            }

            SettingsGroup {
                SettingsRow(
                    icon: AnyView(PromptIcon()),
                    label: "Personalization",
                    action: { viewModel.openPane(.personalization) }
                )
                SettingsRow(
                    icon: AnyView(VerbosityIcon()),
                    label: "Default Verbosity",
                    value: viewModel.settings.defaultVerbosity.displayName,
                    action: { viewModel.openPane(.verbosity) }
                )
                SettingsRow(
                    icon: AnyView(ToolsIcon()),
                    label: "Tools",
                    value: "\(viewModel.tools.filter(\.isEnabled).count) enabled",
                    action: { viewModel.openPane(.tools) }
                )
                SettingsRow(
                    icon: AnyView(CompactionIcon()),
                    label: "Compaction",
                    value: viewModel.settings.autoCompactEnabled ? "Auto" : "Manual",
                    action: { viewModel.openPane(.compaction) }
                )
                SettingsRow(
                    icon: AnyView(SearchIcon()),
                    label: "Search",
                    value: viewModel.settings.askBeforeSearching ? "Ask first" : "Automatic",
                    borderBottom: false,
                    action: { viewModel.openPane(.search) }
                )
            }

            if !appletContributions.isEmpty {
                SettingsGroup {
                    ForEach(Array(appletContributions.enumerated()), id: \.element.id) { index, contribution in
                        SettingsRow(
                            icon: contribution.icon,
                            label: contribution.label,
                            value: contribution.makeValue(),
                            borderBottom: index < appletContributions.count - 1,
                            action: { viewModel.openPane(.appletContributed(id: contribution.id, title: contribution.label)) }
                        )
                    }
                }
            }

            SettingsGroup {
                SettingsRow(
                    icon: AnyView(DataIcon()),
                    label: "Data",
                    value: "\(viewModel.chatCount) chats",
                    action: { viewModel.openPane(.data) }
                )
                SettingsRow(
                    icon: AnyView(AboutIcon()),
                    label: "About",
                    value: aboutVersion,
                    borderBottom: false,
                    action: { viewModel.openPane(.about) }
                )
            }

            Spacer(minLength: 12)
        }
        .padding(.top, 12)
    }

    private var themeName: String {
        SuperTheme.make(viewModel.settings.themeId).displayName
    }

    private var aboutVersion: String {
        "v\(viewModel.appInfo.version)"
    }
}
