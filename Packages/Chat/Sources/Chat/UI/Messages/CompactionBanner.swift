import Core
import SwiftUI

/// Divider strip rendered at the compaction boundary — a "COMPACTED" rule
/// over a tappable summary card. Collapsed by default with the summary
/// clipped to three lines + a "Show more" affordance; tap toggles to the
/// full markdown summary and a "Show less" affordance.
struct CompactionBanner: View {
    let summary: String
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @State private var isExpanded: Bool

    init(summary: String, initiallyExpanded: Bool = false) {
        self.summary = summary
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                line
                Text("COMPACTED")
                    .font(typography.font(.caption2, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(theme.inkFaint)
                line
            }
            Button {
                isExpanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownText(summary, bodyStyleOverride: .banner)
                        .lineLimit(isExpanded ? nil : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(isExpanded ? "Show less" : "Show more")
                        .font(typography.font(.caption2, weight: .medium))
                        .foregroundStyle(theme.inkSoft)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.backgroundSunken)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Compaction summary")
            // Hint adds info beyond the gesture VoiceOver already
            // announces ("double-tap to activate") per Apple HIG. The
            // `.isButton` trait is synthesized by `Button` itself, so no
            // explicit `.accessibilityAddTraits(.isButton)` is needed.
            .accessibilityHint(isExpanded ? "Collapses the summary" : "Expands the summary")
            .animation(.easeInOut(duration: 0.15), value: isExpanded)
        }
        .padding(.vertical, 8)
    }

    private var line: some View {
        Rectangle()
            .fill(theme.borderFaint)
            .frame(height: 1)
    }
}
