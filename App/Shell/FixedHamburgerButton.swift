import Chat
import Core
import SwiftUI

struct FixedHamburgerButton: View {
    let onTap: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// Tracks Dynamic Type while keeping this navigation glyph independent of the app slider.
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
