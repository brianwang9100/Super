import Core
import SwiftUI

// Host inside a shared SuperGlassContainer to avoid independent per-card shadow artifacts.
struct BookmarkSlotButton: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var citationSize: CGFloat = 12

    let color: BibleBookmarkColor
    let assignedCitation: String?
    let isCurrentChapter: Bool
    let currentCitation: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                BookmarkGlyph(
                    state: assignedCitation == nil ? .unassigned(color) : .filled(color),
                    size: 26
                )
                Text(color.displayName)
                    .font(typography.font(size: nameSize, weight: .medium))
                    .foregroundStyle(theme.ink)
                Text(assignedCitation ?? "Empty")
                    .font(typography.font(size: citationSize))
                    .foregroundStyle(assignedCitation == nil ? theme.inkFaint : theme.inkSoft)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .superGlassButton(in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel(Self.label(
            color: color,
            assignedCitation: assignedCitation,
            isCurrentChapter: isCurrentChapter,
            currentCitation: currentCitation
        ))
    }

    // Announce the tap outcome; assignment state alone does not distinguish move from remove.
    static func label(
        color: BibleBookmarkColor,
        assignedCitation: String?,
        isCurrentChapter: Bool,
        currentCitation: String
    ) -> String {
        guard let assignedCitation else {
            return "\(color.displayName) bookmark, empty. Assign to \(currentCitation)"
        }
        if isCurrentChapter {
            return "\(color.displayName) bookmark on \(assignedCitation). Remove bookmark"
        }
        return "\(color.displayName) bookmark on \(assignedCitation). Move to \(currentCitation)"
    }
}
