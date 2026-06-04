import Core
import SwiftUI

/// Appearance pane. Two stacked controls for how the app looks:
/// a 3-column theme grid (Light / Dark / Sepia) of preview cards, and a
/// three-stop font-scale slider snapping to 0.80× / 1.00× / 1.20×
/// (Small / Medium / Large). Spacing (line-spacing, paragraph margin,
/// bubble paddings) is derived from the slider value inside
/// `ChatAppearance`, so larger text automatically gets more breathing
/// room and the pane stays to one knob.
struct SettingsAppearancePane: View {
    @Bindable var viewModel: SettingsViewModel

    /// Local mirror of the slider's value so we can defer the GRDB write
    /// until `onEditingChanged(false)`. Seeded from the view model on
    /// appear; committed on drag end.
    @State private var localFontScale: Double = ChatSettings.default.fontScale

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private static let order: [ChatSettings.ThemeID] = [.light, .dark, .sepia]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Theme")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            themeGrid
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

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
            .font(typography.font(.footnote))
            .tracking(1)
            .foregroundStyle(theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Theme grid

    /// 3-column grid (Light / Dark / Sepia) of preview cards. Each card
    /// paints a miniature of the target theme and gets a 2pt accent
    /// border + 3pt accent halo when selected.
    private var themeGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Self.order, id: \.self) { id in
                themeCard(id: id, palette: SuperTheme.make(id))
            }
        }
    }

    private func themeCard(id: ChatSettings.ThemeID, palette: SuperTheme) -> some View {
        let isSelected = viewModel.settings.themeId == id

        return Button(action: {
            Task { await viewModel.setTheme(id) }
        }) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    palette.background
                        .frame(height: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule()
                            .fill(palette.accent.opacity(0.9))
                            .frame(width: 30, height: 10)
                        Capsule()
                            .fill(palette.ink.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: 6)
                            .padding(.trailing, 30)
                        Capsule()
                            .fill(palette.ink.opacity(0.35))
                            .frame(maxWidth: .infinity, maxHeight: 6)
                            .padding(.trailing, 10)
                        Spacer(minLength: 0)
                        Capsule()
                            .fill(palette.backgroundRaised)
                            .overlay(
                                Capsule().strokeBorder(palette.border, lineWidth: 1)
                            )
                            .frame(maxWidth: .infinity, maxHeight: 16)
                    }
                    .padding(10)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(palette.border)
                        .frame(height: 1)
                }

                HStack(spacing: 6) {
                    Text(palette.displayName)
                        .font(typography.font(.footnote, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Spacer(minLength: 0)
                    if isSelected {
                        CheckIcon(size: 14)
                            .foregroundStyle(theme.accent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Neutral glass card. The colored preview swatch stays opaque on
            // top, so glass frosts only the label footer (the dropped
            // `backgroundRaised` fill); glass also supplies the unselected
            // edge in place of the old neutral border. The selected accent
            // border + halo layer over the glass to keep the picked theme
            // reading as picked.
            .superGlassButton(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.accent, lineWidth: isSelected ? 2 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.22), lineWidth: isSelected ? 3 : 0)
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    // MARK: - Font scale

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
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkFaint)
                Spacer()
                Text("\(Int(round(localFontScale * 100)))%")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkFaint)
                Spacer()
                Text("Large")
                    .font(typography.font(.caption))
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
