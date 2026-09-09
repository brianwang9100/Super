import Chat
import SwiftUI

struct AppletPlaceholderScreen<Icon: View>: View {
    let displayName: String
    let accent: Color
    @ViewBuilder let icon: () -> Icon

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

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
                    .font(typography.display(36))
                    .foregroundStyle(theme.ink)
                Text("Coming soon.")
                    .font(typography.font(.callout))
                    .foregroundStyle(theme.inkSoft)
                Spacer()
                // Reserve space for the minimized chat pill so it cannot obscure the greeting.
                Color.clear.frame(height: 76)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
