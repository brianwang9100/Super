import Chat
import Core
import SwiftUI

/// Shell-level hamburger button. Lives in the top-left of the viewport,
/// outside the chat surface — it survives every `ChatPresentationState`
/// transition unchanged. A 44 × 44pt Liquid Glass circle that floats over the
/// chat surface; the glass supplies its own edge and elevation, so it carries
/// no fill, border, or drop shadow of its own.
struct FixedHamburgerButton: View {
    let onTap: () -> Void

    @Environment(\.superTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "line.3.horizontal")
                .font(.system(.body))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open sidebar")
    }
}
