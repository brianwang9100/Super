import Core
import SwiftUI

/// Top bar of the Settings sheet: leading 44pt circular Liquid Glass button
/// (back chevron on sub-panes, close X on the root pane), centered semibold
/// title, and a hidden 44pt spacer on the trailing edge that keeps the title
/// visually centered.
struct SettingsHeader: View {
    let title: String
    let isRoot: Bool
    let onBack: () -> Void
    let onClose: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        HStack(spacing: 0) {
            iconButton(action: isRoot ? onClose : onBack) {
                if isRoot {
                    CloseIcon(size: 16)
                        .foregroundStyle(theme.ink)
                } else {
                    BackChevronIcon(size: 18)
                        .foregroundStyle(theme.ink)
                }
            }
            .accessibilityLabel(isRoot ? "Close settings" : "Back")

            Text(title)
                .font(typography.font(.body, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            // Hidden spacer mirrors the React `visibility: hidden` button on
            // the trailing edge so the title stays centered to the chrome.
            iconButton(action: {}) {
                CloseIcon(size: 16)
            }
            .hidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func iconButton<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
        }
        .buttonStyle(.plain)
    }
}
