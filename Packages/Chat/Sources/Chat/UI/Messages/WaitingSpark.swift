import SwiftUI

/// Small spinning spark shown while the assistant is "thinking" but
/// hasn't streamed any text yet. Rotates linearly so the user has a
/// clear "still working" cue during the gap between submit and first
/// delta. Reduce Motion swaps the rotation for a static accent-colored
/// spark — the icon still communicates "we're processing" without the
/// continuous spin.
struct WaitingSpark: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        SparkIcon(size: 22, color: theme.accent)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .accessibilityLabel("Thinking")
            .padding(.vertical, 4)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}
