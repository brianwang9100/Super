import SwiftUI

/// Thin progress bar + numeric "used / max" label rendered to the right of
/// the composer footer pills. Width 26pt × height 3pt bar; label in
/// JetBrains Mono at 10.5pt.
///
/// Mirrors the meter inside `Composer` from
/// `.design-tmp/chat/project/src/chat-view.jsx`.
public struct ContextMeter: View {
    public let usedTokens: Int
    public let maxTokens: Int

    public init(usedTokens: Int, maxTokens: Int) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
    }

    @Environment(\.superTheme) private var theme

    private var fillRatio: Double {
        guard maxTokens > 0 else { return 0 }
        return min(1.0, Double(usedTokens) / Double(maxTokens))
    }

    private var labelText: String {
        let usedK = Double(usedTokens) / 1000.0
        let maxK = Double(maxTokens) / 1000.0
        return String(format: "%.1fK / %.0fK", usedK, maxK)
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.border)
                    .frame(width: 26, height: 3)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 26 * fillRatio, height: 3)
            }
            Text(labelText)
                .font(.custom("JetBrainsMono-Regular", size: 10.5, relativeTo: .caption2))
                .foregroundStyle(theme.inkFaint)
        }
        .padding(.trailing, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context")
        .accessibilityValue("\(usedTokens) of \(maxTokens) tokens")
    }
}
