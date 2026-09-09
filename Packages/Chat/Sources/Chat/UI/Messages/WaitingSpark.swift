import SwiftUI

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
