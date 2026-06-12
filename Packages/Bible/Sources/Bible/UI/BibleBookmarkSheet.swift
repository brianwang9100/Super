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
    /// OS Dynamic Type base for the caption, composing with the app
    /// font-scale slider — the dual-axis pattern from `BibleBookSheet`.
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12

    /// Declared once and shared by the nav bar and the presentation so the
    /// two can't drift; a short content-sized sheet.
    private let sizing = SheetSizing.fitsContent

    /// Human-readable citation of the presented chapter, e.g. `"John 3"` —
    /// the nav bar title.
    private let citation: String
    private let currentBookId: String
    private let currentChapterNumber: Int
    /// Resolves a book id to its display name for assigned-slot citations —
    /// the same catalog source the screen's other citation surfaces use.
    private let catalog: BibleBookCatalog
    private let onSelect: (BibleBookmarkColor) -> Void
    private let onClose: () -> Void

    init(
        citation: String,
        currentBookId: String,
        currentChapterNumber: Int,
        catalog: BibleBookCatalog = .standard,
        onSelect: @escaping (BibleBookmarkColor) -> Void,
        onClose: @escaping () -> Void
    ) {
        _bookmarks = Query(constant: AllBookmarksRequest())
        self.citation = citation
        self.currentBookId = currentBookId
        self.currentChapterNumber = currentChapterNumber
        self.catalog = catalog
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
        // A linear scan beats a keyed map at ≤6 rows.
        let record = bookmarks.first { $0.color == color }
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
        let bookName = catalog.book(id: record.bookId)?.name ?? record.bookId
        return "\(bookName) \(record.chapterNumber)"
    }

    private var caption: some View {
        Text("Each color marks one chapter. Reusing a color moves it here.")
            .font(typography.font(size: captionSize))
            .foregroundStyle(theme.inkFaint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 22)
    }
}
