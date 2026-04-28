import SwiftUI

/// Default Verbosity pane. Mirrors `VerbosityPane` from `settings.jsx`: a
/// grouped card with three rows (Simple / Thinking / Verbose), each
/// showing a 15pt label + 12.5pt faint-ink description, with a trailing
/// accent check on the selected row.
struct SettingsVerbosityPane: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme

    private static let options: [(verbosity: ChatVerbosity, description: String)] = [
        (.simple, "Hide thinking and tool calls"),
        (.thinking, "Show thinking, hide tool calls"),
        (.verbose, "Show everything"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup {
                ForEach(Array(Self.options.enumerated()), id: \.offset) { index, option in
                    optionRow(
                        verbosity: option.verbosity,
                        description: option.description,
                        isLast: index == Self.options.count - 1
                    )
                }
            }
        }
        .padding(.top, 16)
    }

    private func optionRow(
        verbosity: ChatVerbosity,
        description: String,
        isLast: Bool
    ) -> some View {
        let isSelected = viewModel.settings.defaultVerbosity == verbosity

        return Button(action: {
            Task { await viewModel.setDefaultVerbosity(verbosity) }
        }) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbosity.displayName)
                        .font(.system(.subheadline))
                        .foregroundStyle(theme.ink)
                    Text(description)
                        .font(.system(.caption))
                        .foregroundStyle(theme.inkFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    CheckGlyph(size: 16)
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(theme.borderFaint)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(verbosity.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
