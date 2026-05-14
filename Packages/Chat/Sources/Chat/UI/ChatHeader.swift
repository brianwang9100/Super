import SwiftUI

/// Sticky chat header. Hamburger menu on the leading edge, centered title,
/// trailing 40×40 spacer to keep the title visually centered without
/// requiring a measured layout.
///
/// Mirrors `ChatHeader` in `.design-tmp/chat/project/src/chat-view.jsx`.
public struct ChatHeader: View {
    public let title: String
    public let onMenuTap: () -> Void

    public init(title: String, onMenuTap: @escaping () -> Void) {
        self.title = title
        self.onMenuTap = onMenuTap
    }

    @Environment(\.superTheme) private var theme
    /// Title tracks the chat font slider so the header resizes with the
    /// message list when the user moves the appearance knob.
    @Environment(\.chatAppearance) private var appearance
    /// Base body size declared via `@ScaledMetric` so Dynamic Type composes
    /// with the chat font-scale knob — same pattern as ``UserBubble``.
    /// Plain `appearance.bodyFont` would drop the Dynamic-Type response
    /// the prior `.subheadline` styling had.
    @ScaledMetric(relativeTo: .subheadline) private var titleBase: CGFloat = 17

    public var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button(action: onMenuTap) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(.body))
                    .foregroundStyle(theme.ink)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(theme.backgroundRaised)
                            .overlay(Circle().stroke(theme.borderFaint, lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open sidebar")

            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: titleBase * appearance.fontScale).weight(.medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Spacer(minLength: 0)

            // Spacer matching the menu button so the title stays centered.
            Color.clear
                .frame(width: 40, height: 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            theme.background.opacity(0.85)
                .background(.ultraThinMaterial)
        )
    }
}
