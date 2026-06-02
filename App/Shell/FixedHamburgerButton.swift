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
    @Environment(\.superTypography) private var typography
    /// Glyph size, declared via `@ScaledMetric` so the icon honors OS Dynamic
    /// Type the way the `.body` text style it replaces did. `tracksFontScale:
    /// false` keeps it independent of the app font-scale slider — this is a
    /// fixed nav affordance, not reading content.
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 17

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "line.3.horizontal")
                .font(typography.font(size: glyphSize, tracksFontScale: false))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open sidebar")
    }
}
