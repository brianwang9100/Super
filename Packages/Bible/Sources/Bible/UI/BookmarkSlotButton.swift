import Core
import SwiftUI

/// One colour slot in the bookmark sheet's 2×3 grid: a centred ribbon glyph
/// (filled in the colour's tint when assigned, a pale wash of that colour when
/// empty), the colour name, and the assigned chapter's citation (or a muted
/// "Empty").
///
/// The card applies its own interactive glass (`superGlassButton`), but the
/// sheet wraps all six cards in one shared `SuperGlassContainer` so they
/// sample a single glass region — independent sampling would cast the
/// fragmented per-cell shadows documented in `BibleBookSheet.chapterGrid`.
struct BookmarkSlotButton: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    // OS Dynamic Type bases, composing with the app font-scale slider that
    // `typography.font(size:)` folds in — the dual-axis pattern from
    // `BibleBookSheet`.
    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var citationSize: CGFloat = 12

    let color: BibleBookmarkColor
    /// Citation of the chapter this colour currently marks, `nil` when the
    /// slot is empty.
    let assignedCitation: String?
    /// Whether the slot's assignment is the chapter the sheet was opened
    /// for — tapping then removes rather than moves.
    let isCurrentChapter: Bool
    /// The presented chapter's citation, for the VoiceOver label.
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

    /// VoiceOver label spelling out what the tap will do — assign, move, or
    /// remove — since the card's visual state alone doesn't say.
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
