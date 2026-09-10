#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

@Suite("BibleBookSheet snapshots", .serialized)
@MainActor
struct BibleBookSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the picker renders with the current book expanded in the light theme")
    func expandedLight() {
        verify(sheet(), theme: .vellumLight, name: "expanded_light")
    }

    @Test("the picker renders with the current book expanded in the dark theme")
    func expandedDark() {
        verify(sheet(), theme: .vellumDark, name: "expanded_dark")
    }

    @Test("a search query collapses the list to matching books")
    func searchLight() {
        verify(sheet(query: "psa"), theme: .vellumLight, name: "search_light")
    }

    @Test("alphabetical order flattens the list")
    func alphabeticalLight() {
        verify(sheet(order: .alphabetical), theme: .vellumLight, name: "alphabetical_light")
    }

    @Test("a query that matches nothing shows the no-results message")
    func noResultsLight() {
        verify(sheet(query: "Zephaniahx"), theme: .vellumLight, name: "no_results_light")
    }

    @Test("the picker renders in the light theme at Dynamic Type XXL")
    func expandedLightXXL() {
        verify(sheet(), theme: .vellumLight, dynamicType: .xxLarge, name: "expanded_light_xxl")
    }

    @Test("a book-only query that matches one book auto-expands its grid")
    func autoExpandLight() {
        verify(sheet(query: "1 Peter"), theme: .vellumLight, name: "auto_expand_light")
    }

    @Test("the auto-expanded grid renders at Dynamic Type XXL")
    func autoExpandLightXXL() {
        verify(
            sheet(query: "1 Peter"),
            theme: .vellumLight, dynamicType: .xxLarge, name: "auto_expand_light_xxl"
        )
    }

    @Test("a book-plus-chapter query shows the single chapter jump row")
    func chapterDeepLinkLight() {
        verify(sheet(query: "1 Peter 2"), theme: .vellumLight, name: "chapter_deep_link_light")
    }

    @Test("a verse-range query shows the verse jump row in the light theme")
    func verseDeepLinkLight() {
        verify(sheet(query: "1 Peter 2:5-6"), theme: .vellumLight, name: "verse_deep_link_light")
    }

    @Test("the verse jump row renders in the dark theme")
    func verseDeepLinkDark() {
        verify(sheet(query: "1 Peter 2:5-6"), theme: .vellumDark, name: "verse_deep_link_dark")
    }

    @Test("the verse jump row renders at Dynamic Type XXL")
    func verseDeepLinkLightXXL() {
        verify(
            sheet(query: "1 Peter 2:5-6"),
            theme: .vellumLight, dynamicType: .xxLarge, name: "verse_deep_link_light_xxl"
        )
    }

    @Test("a mid-canon short-book position anchors the book row at the top")
    func midListLight() {
        verify(
            sheet(currentPosition: BiblePosition(bookId: "ROM", chapterNumber: 8)),
            theme: .vellumLight,
            name: "mid_list_light"
        )
    }

    @Test("a long-book late chapter pulls the chapter cell into view")
    func longBookLateChapterLight() {
        verify(
            sheet(currentPosition: BiblePosition(bookId: "PSA", chapterNumber: 119)),
            theme: .vellumLight,
            name: "long_book_late_chapter_light"
        )
    }

    @Test("the picker renders filled annotation bubbles for books with rows")
    func filledLight() async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleAnnotationRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.replace(
            target: .book, bookId: "GEN", chapterNumber: nil,
            verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "gen-1", target: .book, bookId: "GEN", chapterNumber: nil,
                    summary: "Author — Traditionally Moses.",
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
                    summary: "Compilation — 150 songs across five books.",
                    source: .user, modelId: "afm-3.0", createdAt: now
                )
            ]
        )
        verifyWithDatabase(sheet(), database: database, theme: .vellumLight, name: "filled_light")
    }

    @Test("a book with an in-flight dispatch renders a generating bubble")
    func generatingLight() {
        verify(
            sheet(generatingBookIds: ["GEN"]),
            theme: .vellumLight,
            name: "generating_light"
        )
    }

    @Test("generating bubble renders in the dark theme")
    func generatingDark() {
        verify(
            sheet(generatingBookIds: ["GEN"]),
            theme: .vellumDark,
            name: "generating_dark"
        )
    }

    @Test("the picker renders a filled note glyph for books with a book-level note")
    func noteFilledLight() async throws {
        try await verifyNoteFilled(theme: .vellumLight, name: "note_filled_light")
    }

    @Test("the filled note glyph renders in the dark theme")
    func noteFilledDark() async throws {
        try await verifyNoteFilled(theme: .vellumDark, name: "note_filled_dark")
    }

    // Only book-level notes fill the book glyph; Genesis is visible in the captured frame.
    private func verifyNoteFilled(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleNoteRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.insert(BibleNoteRecord(
            id: "gen-book", target: .book, bookId: "GEN",
            body: "Origins — creation, fall, the patriarchs.",
            source: .user, createdAt: now, updatedAt: now
        ))
        verifyWithDatabase(sheet(), database: database, theme: themeID, name: name, function: function)
    }

    @Test("the picker marks bookmarked chapters with row ribbons and cell badges")
    func bookmarkedLight() async throws {
        try await verifyBookmarked(theme: .vellumLight, name: "bookmarked_light")
    }

    @Test("the bookmarked row + cell indicators render in the dark theme")
    func bookmarkedDark() async throws {
        try await verifyBookmarked(theme: .vellumDark, name: "bookmarked_dark")
    }

    // Two bookmarks exercise both the row ribbon cluster and chapter-cell badges.
    private func verifyBookmarked(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleBookmarkRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.toggle(color: .clay, bookId: "GEN", chapterNumber: 2, at: now)
        try await repository.toggle(color: .gold, bookId: "GEN", chapterNumber: 3, at: now)
        verifyWithDatabase(sheet(), database: database, theme: themeID, name: name, function: function)
    }

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
            onSelectVerseRange: { _, _, _, _ in },
            onClose: {},
            onPresentBookAnnotations: { _ in },
            onRequestBookAnnotations: { _ in },
            onPresentBookNotes: { _ in },
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

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

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

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
