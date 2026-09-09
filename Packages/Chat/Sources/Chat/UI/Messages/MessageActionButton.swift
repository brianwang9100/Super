import SwiftUI

struct MessageActionButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    var disabled: Bool = false
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(typography.font(.caption))
                .foregroundStyle(theme.inkFaint)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }
}
