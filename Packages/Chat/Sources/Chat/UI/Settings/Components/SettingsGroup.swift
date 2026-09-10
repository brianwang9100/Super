import SwiftUI

struct SettingsGroup<Content: View>: View {
    private let content: Content

    @Environment(\.superTheme) private var theme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.borderFaint, lineWidth: 1)
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.backgroundRaised)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
    }
}
