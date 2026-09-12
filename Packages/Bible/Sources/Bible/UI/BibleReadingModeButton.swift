import Core
import SwiftUI

struct BibleReadingModeButton: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16
    let mode: BibleReadingMode
    let onCycle: () -> Void

    var body: some View {
        Button(action: onCycle) {
            Image(systemName: systemImage)
                .font(typography.font(size: glyphSize, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("Reading mode, \(mode.rawValue.capitalized)")
        .accessibilityHint("Switches to \(mode.next.rawValue.capitalized) mode")
    }

    private var systemImage: String {
        switch mode {
        case .book: "book"
        case .compare: "rectangle.split.2x1"
        case .study: "text.bubble"
        }
    }
}
