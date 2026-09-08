import Core
import SwiftUI

/// Floating transcript navigation with the composer accessories' glass and fade.
struct ScrollToBottomButton: View {
    static let diameter: CGFloat = 44
    static let bottomPadding: CGFloat = 8

    /// Read only in the button so geometry updates cannot relayout the transcript.
    @Observable @MainActor
    final class VisibilityState {
        var isVisible = false

        nonisolated static func isAwayFromBottom(_ geometry: ScrollGeometry) -> Bool {
            // SwiftUI's container size already excludes the composer's safe-area
            // inset. Adding contentInsets.bottom would count that space twice.
            geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height > 2
        }
    }

    let visibility: VisibilityState
    let action: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isVisible = visibility.isVisible
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(typography.font(size: 16, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: Self.diameter, height: Self.diameter)
                .superGlassButton(in: Circle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .accessibilityLabel("Scroll to bottom")
        .accessibilityIdentifier("chat-scroll-to-bottom")
        .animation(
            SuperMotion.chrome(hiding: !isVisible, reduceMotion: reduceMotion),
            value: isVisible
        )
    }
}
