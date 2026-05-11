import SwiftUI

/// 7×14pt accent caret. Animated blink suspended when Reduce Motion is on
/// (per AGENTS.md §Testing "Reduce Motion on/off"); the caret stays solid
/// in that case so the streaming surface still indicates activity.
struct TypingCaret: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible: Bool = true

    var body: some View {
        Capsule(style: .continuous)
            .fill(theme.accent)
            .frame(width: 7, height: 14)
            .padding(.leading, 2)
            .offset(y: 2)
            .opacity(visible ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
            .accessibilityHidden(true)
    }
}
