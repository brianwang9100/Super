import Chat
import SwiftUI

/// Empty-state backdrop rendered by each of the four M2 placeholder applets
/// (Todo, Recipes, Bible, Finance). Centered icon + display name in
/// Instrument Serif + a one-line caption — enough to verify the applet
/// switching path and to give M3's chat overlay something to sit on top of.
///
/// The accent strip and icon tint come from the applet's `accentColor` so
/// each placeholder reads differently at a glance per `docs/DESIGN.md §8.2`.
struct AppletPlaceholderScreen<Icon: View>: View {
    let displayName: String
    let accent: Color
    @ViewBuilder let icon: () -> Icon

    @Environment(\.superTheme) private var theme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.12))
                        .frame(width: 96, height: 96)
                    icon()
                        .foregroundStyle(accent)
                }
                Text(displayName)
                    .font(.system(size: 36, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(theme.ink)
                Text("Coming soon.")
                    .font(.system(.callout))
                    .foregroundStyle(theme.inkSoft)
                Spacer()
                // Reserve bottom inset so the M3 chat overlay (minimized
                // pill at the bottom) doesn't permanently obscure the
                // greeting. ~68pt matches the pill + bottom safe-area
                // reserve documented in `docs/DESIGN.md §4.3`.
                Color.clear.frame(height: 76)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
