import SwiftUI

struct SettingsSearchPane: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                toggleRow
            }
            footnote
                .padding(.horizontal, 24)
        }
        .padding(.top, 16)
    }

    private var toggleRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask before each search")
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.ink)
                Text("Confirm before the assistant searches the web")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsToggle(
                isOn: Binding(
                    get: { viewModel.settings.askBeforeSearching },
                    set: { newValue in
                        Task { await viewModel.setAskBeforeSearching(newValue) }
                    }
                ),
                accessibilityLabel: "Ask before each search"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private var footnote: some View {
        Text("Web searches use the model's own provider key and may cost money. When off, the assistant searches without asking.")
            .font(typography.font(.caption))
            .foregroundStyle(theme.inkFaint)
            .padding(.top, 4)
    }
}
