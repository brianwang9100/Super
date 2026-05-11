import SwiftUI

/// Appearance pane. Mirrors `AppearancePane` from `settings.jsx`: a
/// raised card with a 0.85×–1.15× font scale slider, then a grouped card
/// with three density rows (Compact / Comfortable / Spacious).
struct SettingsAppearancePane: View {
    @Bindable var viewModel: SettingsViewModel

    /// Local mirror of the slider's value so we can defer the GRDB write
    /// until `onEditingChanged(false)`. Seeded from the view model on
    /// appear; committed on drag end.
    @State private var localFontScale: Double = ChatSettings.default.fontScale

    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Font size")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            fontScaleCard
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

            sectionLabel("Density")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            SettingsGroup {
                ForEach(Array(ChatSettings.Density.allCases.enumerated()), id: \.element) { index, density in
                    densityRow(
                        density: density,
                        isLast: index == ChatSettings.Density.allCases.count - 1
                    )
                }
            }
        }
        .padding(.top, 16)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.footnote))
            .tracking(1)
            .foregroundStyle(theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fontScaleCard: some View {
        VStack(spacing: 6) {
            Slider(
                value: $localFontScale,
                in: 0.85...1.15,
                step: 0.05,
                onEditingChanged: { editing in
                    // Commit only when the drag ends so we don't fire
                    // one GRDB write per intermediate step.
                    if !editing {
                        Task { await viewModel.setFontScale(localFontScale) }
                    }
                }
            )
            .tint(theme.accent)

            HStack {
                Text("Small")
                    .font(.system(.caption))
                    .foregroundStyle(theme.inkFaint)
                Spacer()
                Text("\(Int(round(localFontScale * 100)))%")
                    .font(.system(.caption))
                    .foregroundStyle(theme.inkFaint)
                Spacer()
                Text("Large")
                    .font(.system(.caption))
                    .foregroundStyle(theme.inkFaint)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.backgroundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.borderFaint, lineWidth: 1)
        )
        .onAppear { localFontScale = viewModel.settings.fontScale }
    }

    private func densityRow(density: ChatSettings.Density, isLast: Bool) -> some View {
        let isSelected = viewModel.settings.density == density

        return Button(action: {
            Task { await viewModel.setDensity(density) }
        }) {
            HStack(spacing: 14) {
                Text(density.displayName)
                    .font(.system(.subheadline))
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    CheckIcon(size: 16)
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
        .accessibilityLabel(density.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
