import SwiftUI

struct CopyConfirmationPill: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(theme.ink.opacity(0.92))
            Text("Copied!")
                .font(typography.font(.footnote, weight: .medium))
                .foregroundStyle(theme.background)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .fixedSize()
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
        .accessibilityLabel("Copied to clipboard")
    }
}
