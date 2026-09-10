import Core
import GRDBQuery
import SwiftUI

struct BibleBookmarkSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Query<AllBookmarksRequest> private var bookmarks: [BibleBookmarkRecord]
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12

    private let sizing = SheetSizing.fitsContent

    private let citation: String
    private let currentBookId: String
    private let currentChapterNumber: Int
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

    private static let columns = 2

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: citation, sizing: sizing, onClose: onClose)
            slotGrid
            caption
        }
        .sheetPresentation(sizing, estimatedHeight: 420)
    }

    // Share glass sampling without merging cards to avoid per-cell shadow artifacts.
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

    /// Unknown books retain their code; citations remain translation-independent.
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
