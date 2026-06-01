import SwiftUI

/// Compaction pane. Not in `settings.jsx` — designed to match the same
/// visual language. A single grouped card holds the auto-compaction toggle
/// row and a slider for the trigger threshold (50%–95% of the active
/// model's context window).
struct SettingsCompactionPane: View {
    @Bindable var viewModel: SettingsViewModel

    /// Local mirror of the slider's value so we can defer the GRDB write
    /// until `onEditingChanged(false)`.
    @State private var localThreshold: Double = ChatSettings.default.autoCompactThreshold

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                toggleRow
                thresholdRow
            }
            footnote
                .padding(.horizontal, 24)
        }
        .padding(.top, 16)
    }

    private var toggleRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-compact")
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.ink)
                Text("Summarize older turns when context fills up")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsToggle(
                isOn: Binding(
                    get: { viewModel.settings.autoCompactEnabled },
                    set: { newValue in
                        Task { await viewModel.setAutoCompactEnabled(newValue) }
                    }
                ),
                accessibilityLabel: "Auto-compact"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 1)
                .padding(.leading, 16)
        }
    }

    private var thresholdRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trigger at")
                    .font(typography.font(.subheadline))
                    .foregroundStyle(viewModel.settings.autoCompactEnabled ? theme.ink : theme.inkMute)
                Spacer()
                Text("\(Int(round(localThreshold * 100)))%")
                    .font(typography.mono(12, relativeTo: .caption))
                    .foregroundStyle(theme.inkFaint)
            }
            Slider(
                value: $localThreshold,
                in: 0.5...0.95,
                step: 0.05,
                onEditingChanged: { editing in
                    if !editing {
                        Task { await viewModel.setAutoCompactThreshold(localThreshold) }
                    }
                }
            )
            .tint(theme.accent)
            .disabled(!viewModel.settings.autoCompactEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .onAppear { localThreshold = viewModel.settings.autoCompactThreshold }
    }

    private var footnote: some View {
        Text("Lower values compact sooner. Older turns are replaced with a summary.")
            .font(typography.font(.caption))
            .foregroundStyle(theme.inkFaint)
            .padding(.top, 4)
    }
}
