import SwiftUI

/// Top bar of the Settings sheet. Mirrors the `Header` block in
/// `settings.jsx`: leading 32pt circular button (back chevron on sub-panes,
/// close X on the root pane), centered semibold title, hidden 32pt spacer
/// on the trailing edge that keeps the title visually centered.
struct SettingsHeader: View {
    let title: String
    let isRoot: Bool
    let onBack: () -> Void
    let onClose: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// Title base size. The Settings top bar is chrome (a fixed-height,
    /// single-line nav bar), so the title must stay off the font-scale slider —
    /// `tracksFontScale: false` keeps it scoped to the pane's reading content
    /// below, while `@ScaledMetric` still composes OS Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 17

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
                .font(typography.font(size: titleSize, weight: .semibold, tracksFontScale: false))
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
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(theme.backgroundRaised)
                )
                .overlay(
                    Circle().strokeBorder(theme.borderFaint, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
