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
    @Test("the picker renders filled annotation bubbles for books with rows")
    func filledLight() async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleAnnotationRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Seed two books with annotations across the canon — Genesis at
        // the top and Psalms in the middle — so both the always-visible
        // expanded Genesis row and a scrolled mid-list row exercise the
        // filled-glyph layout.
        try await repository.replace(
            target: .book, bookId: "GEN", chapterNumber: nil,
            verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "gen-1", target: .book, bookId: "GEN", chapterNumber: nil,
                    kind: .text, title: "Author", body: "Traditionally Moses.",
                    source: .user, modelId: "afm-3.0", createdAt: now
                )
            ]
        )
        try await repository.replace(
            target: .book, bookId: "PSA", chapterNumber: nil,
            verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "psa-1", target: .book, bookId: "PSA", chapterNumber: nil,
                    kind: .text, title: "Compilation", body: "150 songs across five books.",
                    source: .user, modelId: "afm-3.0", createdAt: now
                )
            ]
        )
        verifyWithDatabase(sheet(), database: database, theme: .light, name: "filled_light")
    }

    @Test("a book with an in-flight dispatch renders a generating bubble")
    func generatingLight() {
        // No database context → no rows, so Genesis is unannotated; the
        // generating set flips its bubble to the dotted in-flight glyph.
        verify(
            sheet(generatingBookIds: ["GEN"]),
            theme: .light,
            name: "generating_light"
        )
    }

    @Test("generating bubble renders in the dark theme")
    func generatingDark() {
        verify(
            sheet(generatingBookIds: ["GEN"]),
            theme: .dark,
            name: "generating_dark"
        )
    }

    @Test("generating bubble renders in the sepia theme")
    func generatingSepia() {
        verify(
            sheet(generatingBookIds: ["GEN"]),
            theme: .sepia,
            name: "generating_sepia"
        )
    }

    /// A `BibleBookSheet` opened on the given current position (defaulting
    /// to Genesis 1, which keeps the existing baselines stable), in the
    /// given order with the given query applied.
    private func sheet(
        currentPosition: BiblePosition = BiblePosition(bookId: "GEN", chapterNumber: 1),
        order: BibleBookOrder = .traditional,
        query: String = "",
        generatingBookIds: Set<String> = []
    ) -> BibleBookSheet {
        let viewModel = BibleBookSheetViewModel(currentPosition: currentPosition)
        viewModel.order = order
        viewModel.query = query
        return BibleBookSheet(
            viewModel: viewModel,
            currentBookId: currentPosition.bookId,
            currentChapterNumber: currentPosition.chapterNumber,
            onSelectChapter: { _, _ in },
            onClose: {},
            onPresentBookAnnotations: { _ in },
            onRequestBookAnnotations: { _ in },
            generatingBookIds: generatingBookIds
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

    /// Snapshot driver that attaches a real `DatabaseContext` so the
    /// picker's `@Query<BookAnnotationsExistenceRequest>` returns the
    /// seeded set instead of falling back to its empty default. Used by
    /// the filled-bubble variant.
    private func verifyWithDatabase(
        _ sheet: BibleBookSheet,
        database: BibleDatabase,
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
        .databaseContext(.readOnly { database.queue })

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
