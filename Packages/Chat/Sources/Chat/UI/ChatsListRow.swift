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
    /// via `RelativeTimeFormatter`. Caller injects the reference `now`
    /// + `calendar` so the row stays pure for snapshot determinism.
    let updatedAt: Date

    /// Reference time for the relative-time bucketing.
    let now: Date

    /// Calendar passed through to `RelativeTimeFormatter`.
    let calendar: Calendar

    /// Fires when the row is tapped. The screen wires this to publish
    /// `.openConversationRequested(id:)` on the shared event bus.
    let onTap: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var subtitleSize: CGFloat = 11.5
    @Environment(\.superFontScale) private var fontScale
    @Environment(\.superTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: titleSize * fontScale).weight(.medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(RelativeTimeFormatter.format(updatedAt, now: now, calendar: calendar))
                        .font(.system(size: subtitleSize * fontScale))
                        .foregroundStyle(theme.inkFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
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
