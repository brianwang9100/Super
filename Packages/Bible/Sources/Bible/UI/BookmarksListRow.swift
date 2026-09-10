import Core
import SwiftUI

struct BookmarksListRow: View {
    let color: BibleBookmarkColor
    let citation: String?
    /// Nil renders an inert row rather than a button.
    let onTap: (() -> Void)?

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
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
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
        }
    }
}
