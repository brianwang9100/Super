import Core
import SwiftUI

/// A safe-area inset reserves the measured content height in the reader scroll viewport.
struct BibleStudyBar<Content: View>: View {
    @Environment(\.superTheme) private var theme
    let onHeightChange: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(theme.backgroundRaised)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeightChange)
    }
}
