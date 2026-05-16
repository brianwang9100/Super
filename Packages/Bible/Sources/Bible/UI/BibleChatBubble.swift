import Core
import SwiftUI

/// The floating "Ask about this chapter…" pill shown at the foot of the
/// reader when no verses are selected.
///
/// A no-op stand-in this milestone: tapping it raises the same "chat ships
/// later" toast as the `+` button, since chat hand-off is deferred.
struct BibleChatBubble: View {
    @Environment(\.superTheme) private var theme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 14, weight: .medium))
                Text("Ask about this chapter…")
                    .font(.system(size: 14))
                Spacer(minLength: 8)
                Image(systemName: "mic")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(theme.inkFaint)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 22).fill(theme.backgroundRaised))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(theme.borderFaint, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask about this chapter")
    }
}
