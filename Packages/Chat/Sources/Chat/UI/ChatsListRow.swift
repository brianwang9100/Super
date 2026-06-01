import Core
import Foundation
import SwiftUI

/// One row in the Chats applet's list — title + relative-time subtitle
/// + trailing chevron, with a hairline divider beneath. Matches the
/// design's chats/app.jsx `ChatRow`.
struct ChatsListRow: View {
    /// Visible title — already nil-coalesced to "New chat" by the
    /// caller so the row never has to decide its own fallback text.
    let title: String

    /// Timestamp rendered as "12 min ago" / "Yesterday" / "3 mo ago"
    /// via `RelativeTimeFormatter`. The screen injects `now` so the
    /// row stays pure for snapshot determinism.
    let updatedAt: Date

    /// Reference time for the relative-time bucketing.
    let now: Date

    /// Fires when the row is tapped. The screen wires this to publish
    /// `.openConversationRequested(id:)` on the shared event bus.
    let onTap: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// Row title + subtitle base sizes, declared via `@ScaledMetric` so
    /// they compose OS Dynamic Type on top of the app font-scale that
    /// `SuperTypography` folds in. The typography system path ignores
    /// `relativeTo`, so these metrics are how the row opts into Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var subtitleSize: CGFloat = 11.5

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(typography.font(size: titleSize, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(RelativeTimeFormatter.format(updatedAt, now: now))
                        .font(typography.font(size: subtitleSize))
                        .foregroundStyle(theme.inkFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(typography.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.inkMute)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                // Hairline divider — 0.5pt at native scale, achieved
                // with a 1pt frame scaled at 0.5 below.
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}
