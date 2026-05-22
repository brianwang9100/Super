import SwiftUI

/// Transient HUD pill rendered above the composer for ~1.2 s after the
/// user taps Copy on an assistant message. Presence-driven only — the
/// dwell timer and the visibility flag live on ``ChatScreenViewModel``
/// (`showCopyConfirmation`, `confirmCopy()`), so this view has no state
/// of its own and is safe to re-mount on every show.
struct CopyConfirmationPill: View {
    @Environment(\.superTheme) private var theme

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(theme.ink.opacity(0.92))
            Text("Copied!")
                .font(.system(.footnote, weight: .medium))
                .foregroundColor(theme.background)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .fixedSize()
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
        .accessibilityLabel("Copied to clipboard")
    }
}
