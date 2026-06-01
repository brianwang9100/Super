import SwiftUI

/// Tools pane. Not in `settings.jsx` — designed to match the same visual
/// language. One grouped card with one row per registered tool: name +
/// faint-ink description + trailing toggle.
struct SettingsToolsPane: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.tools.isEmpty {
                emptyState
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
            } else {
                SettingsGroup {
                    ForEach(Array(viewModel.tools.enumerated()), id: \.element.id) { index, tool in
                        toolRow(
                            tool: tool,
                            isLast: index == viewModel.tools.count - 1
                        )
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    private func toolRow(tool: SettingsViewModel.ToolRow, isLast: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.ink)
                Text(tool.summary)
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkFaint)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Gear appears only for tools that declare a config pane AND
            // are enabled — no point configuring an off tool. Pushes
            // onto the existing sheet `NavigationStack` rather than
            // presenting a nested modal.
            if let pane = tool.configPane, tool.isEnabled {
                Button {
                    viewModel.openPane(pane)
                } label: {
                    Image(systemName: "gearshape")
                        .font(typography.font(size: 16, weight: .regular))
                        .foregroundStyle(theme.inkSoft)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure \(tool.name)")
            }

            SettingsToggle(
                isOn: Binding(
                    get: { tool.isEnabled },
                    set: { newValue in
                        Task { await viewModel.setToolEnabled(id: tool.id, enabled: newValue) }
                    }
                ),
                accessibilityLabel: tool.name
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No tools registered")
                .font(typography.font(.subheadline))
                .foregroundStyle(theme.inkSoft)
            Text("Tools surface here as applets register them.")
                .font(typography.font(.caption))
                .foregroundStyle(theme.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
