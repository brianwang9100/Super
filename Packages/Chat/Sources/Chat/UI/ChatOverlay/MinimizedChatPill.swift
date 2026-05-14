import SwiftUI

/// The "Chat with Super" pill rendered at the bottom of the viewport when
/// the chat is in the ``ChatPresentationState/minimized`` state. Tap to
/// expand back to ``ChatPresentationState/semiExpanded``.
///
/// Geometry per the 2026-05-13 design (`chat.jsx` → `StateBubble`):
/// left/right inset 12pt, bottom inset 14pt + safe-area, radius 24, raised
/// surface, two-layer drop shadow.
public struct MinimizedChatPill: View {
    /// Tapped to climb back to ``ChatPresentationState/semiExpanded``.
    public let onTap: () -> Void

    public init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    @Environment(\.superTheme) private var theme

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text("Chat with Super")
                    .font(.system(.body))
                    .foregroundStyle(theme.inkFaint)
                Spacer(minLength: 0)
                Image(systemName: "mic")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.inkSoft)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(theme.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(theme.borderFaint, lineWidth: 1)
            )
            // Two-layer shadow stack to match the design's lifted feel.
            // Lower-Z subtle near-shadow + larger ambient far-shadow.
            .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 12)
            .shadow(color: Color.black.opacity(0.10), radius: 30, x: 0, y: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open chat")
        .accessibilityHint("Tap to expand the chat panel")
    }
}
