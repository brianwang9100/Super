#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleBookSheet` — the book picker in its default expanded
/// state across the three themes, plus the search, alphabetical, and
/// no-results variants and one Dynamic Type XXL pass.
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

    /// A `BibleBookSheet` with Genesis as the reader's current book — it is
    /// expanded at the top of the list, so the chapter grid is on screen —
    /// in the given order with the given query applied.
    private func sheet(order: BibleBookOrder = .traditional, query: String = "") -> BibleBookSheet {
        let viewModel = BibleBookSheetViewModel(expandedBookId: "GEN")
        viewModel.order = order
        viewModel.query = query
        return BibleBookSheet(
            viewModel: viewModel,
            currentBookId: "GEN",
            currentChapterNumber: 1,
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
