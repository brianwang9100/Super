import SwiftUI

/// Theme pane. Mirrors `ThemePane` from `settings.jsx`: a 3-column grid
/// (Light / Dark / Sepia) of preview cards. Each card paints a miniature of
/// the target theme and gets a 2pt accent border + 3pt accent halo when
/// selected.
struct SettingsThemePane: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme

    private static let order: [ChatSettings.ThemeID] = [.light, .dark, .sepia]

    var body: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Self.order, id: \.self) { id in
                themeCard(id: id, palette: SuperTheme.make(id))
            }
        }
        .padding(16)
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
                        .font(.system(.footnote).weight(.medium))
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
                .background(theme.backgroundRaised)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : theme.border,
                        lineWidth: isSelected ? 2 : 1
                    )
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
}
