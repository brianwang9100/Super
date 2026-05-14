import Chat
import SwiftUI

/// Shell-level hamburger button. Lives in the top-left of the viewport,
/// outside the chat surface — it survives every `ChatPresentationState`
/// transition unchanged. 36 × 36pt raised pill with a blurred backdrop and
/// soft card shadow, per the 2026-05-13 design
/// (`/tmp/super-design/super/project/ds/chat.jsx` → `FixedHamburger`).
struct FixedHamburgerButton: View {
    let onTap: () -> Void

    @Environment(\.superTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "line.3.horizontal")
                .font(.system(.body))
                .foregroundStyle(theme.ink)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(theme.backgroundRaised.opacity(0.85))
                        .background(.ultraThinMaterial, in: Circle())
                )
                .overlay(
                    Circle()
                        .strokeBorder(theme.borderFaint, lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 5, x: 0, y: 2)
                .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open sidebar")
    }
}
