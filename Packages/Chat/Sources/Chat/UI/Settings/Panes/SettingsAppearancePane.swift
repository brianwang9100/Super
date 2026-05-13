import SwiftUI

/// Appearance pane. A single raised card with a three-stop font-scale
/// slider snapping to 0.80× / 1.00× / 1.20× (Small / Medium / Large).
/// Spacing (line-spacing, paragraph margin, bubble paddings) is
/// derived from the slider value inside `ChatAppearance`, so larger
/// text automatically gets more breathing room and the pane stays to
/// one knob.
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
                in: 0.80...1.20,
                step: 0.20,
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
}
