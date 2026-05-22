#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleBookSheet` — the book picker in its default expanded
/// state across the three themes, the search, alphabetical, and no-results
/// variants, one Dynamic Type XXL pass, plus two scroll-anchor variants
/// covering the mid-canon short-book and long-book late-chapter branches.
@Suite("BibleBookSheet snapshots")
@MainActor
struct BibleBookSheetSnapshotTests {
    @Test("the picker renders with the current book expanded in the light theme")
    func expandedLight() {
        verify(sheet(), theme: .light, name: "expanded_light")
    }

    @Test("the picker renders with the current book expanded in the dark theme")
    func expandedDark() {
        verify(sheet(), theme: .dark, name: "expanded_dark")
    }

    @Test("the picker renders with the current book expanded in the sepia theme")
    func expandedSepia() {
        verify(sheet(), theme: .sepia, name: "expanded_sepia")
    }

    @Test("a search query collapses the list to matching books")
    func searchLight() {
        verify(sheet(query: "psa"), theme: .light, name: "search_light")
    }

    @Test("alphabetical order flattens the list")
    func alphabeticalLight() {
        verify(sheet(order: .alphabetical), theme: .light, name: "alphabetical_light")
    }

    @Test("a query that matches nothing shows the no-results message")
    func noResultsLight() {
        verify(sheet(query: "Zephaniahx"), theme: .light, name: "no_results_light")
    }

    @Test("the picker renders in the light theme at Dynamic Type XXL")
    func expandedLightXXL() {
        verify(sheet(), theme: .light, dynamicType: .xxLarge, name: "expanded_light_xxl")
    }

    @Test("a mid-canon short-book position anchors the book row at the top")
    func midListLight() {
        verify(
            sheet(currentPosition: BiblePosition(bookId: "ROM", chapterNumber: 8)),
            theme: .light,
            name: "mid_list_light"
        )
    }

    @Test("a long-book late chapter pulls the chapter cell into view")
    func longBookLateChapterLight() {
        verify(
            sheet(currentPosition: BiblePosition(bookId: "PSA", chapterNumber: 119)),
            theme: .light,
            name: "long_book_late_chapter_light"
        )
    }

    /// A `BibleBookSheet` opened on the given current position (defaulting
    /// to Genesis 1, which keeps the existing baselines stable), in the
    /// given order with the given query applied.
    private func sheet(
        currentPosition: BiblePosition = BiblePosition(bookId: "GEN", chapterNumber: 1),
        order: BibleBookOrder = .traditional,
        query: String = ""
    ) -> BibleBookSheet {
        let viewModel = BibleBookSheetViewModel(currentPosition: currentPosition)
        viewModel.order = order
        viewModel.query = query
        return BibleBookSheet(
            viewModel: viewModel,
            currentBookId: currentPosition.bookId,
            currentChapterNumber: currentPosition.chapterNumber,
            bottomInset: 0,
            onSelectChapter: { _, _ in },
            onClose: {}
        )
    }

    private func verify(
        _ sheet: BibleBookSheet,
        theme themeID: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .top) {
            theme.background
            sheet.padding(.top, 80)
        }
        .frame(width: 402, height: 760)
        .dynamicTypeSize(dynamicType)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
