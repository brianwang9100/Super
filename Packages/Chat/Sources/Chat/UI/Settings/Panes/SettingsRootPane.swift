import Core
import SwiftUI

/// Root pane of the Settings sheet. Mirrors the root layout in
/// `settings.jsx`: account chip · Models/Appearance group · System Prompt /
/// Verbosity / Tools / Compaction group · Data / About group.
///
/// Row taps push panes via the view model's navigation helper so the
/// `NavigationStack` in `SettingsSheet` animates the transition and
/// external deep-links go through the same code path.
struct SettingsRootPane: View {
    let viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            accountChip
                .padding(.top, 12)
                .padding(.bottom, 14)

            SettingsGroup {
                SettingsRow(
                    icon: AnyView(ModelsIcon()),
                    label: "Models",
                    value: "\(viewModel.models.count) configured",
                    action: { viewModel.openPane(.models) }
                )
                SettingsRow(
                    icon: AnyView(ThemeIcon()),
                    label: "Appearance",
                    value: themeName,
                    borderBottom: false,
                    action: { viewModel.openPane(.appearance) }
                )
            }

            SettingsGroup {
                SettingsRow(
                    icon: AnyView(PromptIcon()),
                    label: "System Prompt",
                    action: { viewModel.openPane(.prompt) }
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
                    borderBottom: false,
                    action: { viewModel.openPane(.compaction) }
                )
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
    }

    private var themeName: String {
        SuperTheme.make(viewModel.settings.themeId).displayName
    }

    private var accountChip: some View {
        Text(viewModel.accountEmail)
            .font(.system(.subheadline))
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.borderFaint, lineWidth: 1)
            )
            .padding(.horizontal, 16)
    }

    private var aboutVersion: String {
        "v\(viewModel.appInfo.version)"
    }
}
