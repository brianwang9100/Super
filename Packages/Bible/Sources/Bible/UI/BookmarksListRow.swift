import Core
import SwiftUI

/// One row in the Bookmarks applet's list: a filled ribbon (or a pale wash of
/// the colour when empty), the colour name, and the chapter it marks — or a muted
/// "Empty slot" when unassigned. An assigned row is a tappable button that
/// opens the chapter; an empty row is inert text with no tap target.
struct BookmarksListRow: View {
    let color: BibleBookmarkColor
    /// The marked chapter's citation (`"John 3"`), or `nil` for an empty slot.
    let citation: String?
    /// Fires when an assigned row is tapped; `nil` for an empty slot, which
    /// renders without a button so it can't be activated.
    let onTap: (() -> Void)?

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    // Row title + subtitle bases, declared via `@ScaledMetric` so they
    // compose OS Dynamic Type on top of the app font-scale slider that
    // `typography.font(size:)` folds in — the dual-axis pattern.
    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var citationSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 22

    var body: some View {
        if let citation, let onTap {
            Button(action: onTap) {
                rowContent(citation: citation)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(BookmarksScreen.rowLabel(color: color, citation: citation))
        } else {
            rowContent(citation: nil)
                .accessibilityLabel("\(color.displayName) bookmark, empty slot")
        }
    }

    private func rowContent(citation: String?) -> some View {
        HStack(spacing: 12) {
            BookmarkGlyph(
                state: citation == nil ? .unassigned(color) : .filled(color),
                size: glyphSize
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(color.displayName)
                    .font(typography.font(size: nameSize, weight: .medium))
                    .foregroundStyle(citation == nil ? theme.inkFaint : theme.ink)
                Text(citation ?? "Empty slot")
                    .font(typography.font(size: citationSize))
                    .foregroundStyle(theme.inkFaint)
            }
            Spacer(minLength: 4)
            if citation != nil {
                Image(systemName: "chevron.right")
                    .font(typography.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.inkMute)
            }
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            // Hairline divider — 0.5pt at native scale, matching ChatsListRow.
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
        }
    }
}
