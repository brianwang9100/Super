import Core
import GRDBQuery
import SwiftUI

/// The bookmark picker: a short content-sized sheet titled with the chapter's
/// citation, presenting the six colour slots as a 2×3 card grid over the live
/// `AllBookmarksRequest` observation, with a one-line caption explaining the
/// move-on-reuse rule.
///
/// Tapping any card funnels into one `onSelect(color)` — the repository's
/// atomic toggle resolves it to assign, move, or unassign — and the grid
/// repaints mid-presentation through the `@Query` once the write lands.
struct BibleBookmarkSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Query<AllBookmarksRequest> private var bookmarks: [BibleBookmarkRecord]

    /// Declared once and shared by the nav bar and the presentation so the
    /// two can't drift; a short content-sized sheet.
    private let sizing = SheetSizing.fitsContent

    /// Human-readable citation of the presented chapter, e.g. `"John 3"` —
    /// the nav bar title.
    private let citation: String
    private let currentBookId: String
    private let currentChapterNumber: Int
    /// Extra bottom padding so the grid clears the shell's minimized chat
    /// pill; `0` in standalone (snapshot) contexts.
    private let bottomInset: CGFloat
    private let onSelect: (BibleBookmarkColor) -> Void
    private let onClose: () -> Void

    init(
        citation: String,
        currentBookId: String,
        currentChapterNumber: Int,
        bottomInset: CGFloat = 0,
        onSelect: @escaping (BibleBookmarkColor) -> Void,
        onClose: @escaping () -> Void
    ) {
        _bookmarks = Query(constant: AllBookmarksRequest())
        self.citation = citation
        self.currentBookId = currentBookId
        self.currentChapterNumber = currentChapterNumber
        self.bottomInset = bottomInset
        self.onSelect = onSelect
        self.onClose = onClose
    }

    /// The grid's fixed shape: six slots, two per row.
    private static let columns = 2

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: citation, sizing: sizing, onClose: onClose)
            slotGrid
            caption
        }
        .sheetPresentation(sizing, estimatedHeight: 420)
    }

    /// Bookmark rows keyed by colour, decoded from the observed table.
    private var bookmarksByColor: [BibleBookmarkColor: BibleBookmarkRecord] {
        var map: [BibleBookmarkColor: BibleBookmarkRecord] = [:]
        for record in bookmarks {
            guard let color = record.color else { continue }
            map[color] = record
        }
        return map
    }

    /// One shared glass sampling region for all six cards — per-card glass
    /// would cast the fragmented per-cell shadows documented in
    /// `BibleBookSheet.chapterGrid`. `spacing: 0` shares the region without
    /// merging; the 10pt gaps keep the cards separated.
    private var slotGrid: some View {
        let colors = BibleBookmarkColor.allCases
        let rowCount = (colors.count + Self.columns - 1) / Self.columns
        return SuperGlassContainer(spacing: 0) {
            VStack(spacing: 10) {
                ForEach(0..<rowCount, id: \.self) { rowIndex in
                    HStack(spacing: 10) {
                        ForEach(0..<Self.columns, id: \.self) { column in
                            let index = rowIndex * Self.columns + column
                            if index < colors.count {
                                slotCard(colors[index])
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private func slotCard(_ color: BibleBookmarkColor) -> some View {
        let record = bookmarksByColor[color]
        let isCurrentChapter = record?.bookId == currentBookId
            && record?.chapterNumber == currentChapterNumber
        return BookmarkSlotButton(
            color: color,
            assignedCitation: record.map(citation(for:)),
            isCurrentChapter: isCurrentChapter,
            currentCitation: citation,
            onTap: { onSelect(color) }
        )
    }

    /// `"John 3"`-style citation for an assigned slot. Falls back to the raw
    /// book code for an id outside the catalog (can't happen for rows the
    /// sheet itself wrote). Deliberately translation-free — a bookmark marks
    /// the chapter, not an edition.
    private func citation(for record: BibleBookmarkRecord) -> String {
        let bookName = BibleBookIndex.entry(id: record.bookId)?.name ?? record.bookId
        return "\(bookName) \(record.chapterNumber)"
    }

    private var caption: some View {
        Text("Each color marks one chapter. Reusing a color moves it here.")
            .font(typography.font(size: 12))
            .foregroundStyle(theme.inkFaint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 22 + bottomInset)
    }
}
