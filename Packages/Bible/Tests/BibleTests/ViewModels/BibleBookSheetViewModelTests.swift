import Testing
@testable import Bible

/// Tests for `BibleBookSheetViewModel` — search filtering, traditional vs
/// alphabetical ordering and grouping, the no-results case, which book is
/// auto-expanded from the reader's current position, and which scroll
/// anchor that position resolves to.
@Suite("BibleBookSheetViewModel")
@MainActor
struct BibleBookSheetViewModelTests {
    private func makeViewModel(
        currentPosition: BiblePosition? = BiblePosition(bookId: "1PE", chapterNumber: 1)
    ) -> BibleBookSheetViewModel {
        BibleBookSheetViewModel(currentPosition: currentPosition)
    }

    @Test("traditional order splits the canon into Old and New Testament")
    func traditionalGroupsByTestament() {
        let viewModel = makeViewModel()
        let groups = viewModel.groups
        #expect(groups.count == 2)
        #expect(groups[0].title == "Old Testament")
        #expect(groups[0].books.count == 39)
        #expect(groups[0].books.first?.id == "GEN")
        #expect(groups[1].title == "New Testament")
        #expect(groups[1].books.count == 27)
        #expect(groups[1].books.last?.id == "REV")
        #expect(viewModel.hasResults)
    }

    @Test("a search query collapses the list into one untitled group")
    func searchFiltersToSingleGroup() {
        let viewModel = makeViewModel()
        viewModel.query = "psa"
        let groups = viewModel.groups
        #expect(groups.count == 1)
        #expect(groups[0].title == nil)
        #expect(groups[0].books.map(\.id) == ["PSA"])
    }

    @Test("a search query matches books across both testaments")
    func searchMatchesAcrossTestaments() {
        let viewModel = makeViewModel()
        viewModel.query = "john"
        #expect(viewModel.groups.count == 1)
        #expect(viewModel.groups[0].books.map(\.id) == ["JHN", "1JN", "2JN", "3JN"])
    }

    @Test("whitespace around the query is ignored")
    func searchTrimsWhitespace() {
        let viewModel = makeViewModel()
        viewModel.query = "  psalms  "
        #expect(viewModel.groups.first?.books.map(\.id) == ["PSA"])

        viewModel.query = "   "
        #expect(viewModel.groups.count == 2)
    }

    @Test("a query that matches nothing yields no results")
    func searchWithNoMatchHasNoResults() {
        let viewModel = makeViewModel()
        viewModel.query = "Nonexistent"
        #expect(viewModel.groups.isEmpty)
        #expect(viewModel.hasResults == false)
    }

    @Test("alphabetical order flattens all 66 books into one sorted group")
    func alphabeticalFlattensAndSorts() {
        let viewModel = makeViewModel()
        viewModel.order = .alphabetical
        let groups = viewModel.groups
        #expect(groups.count == 1)
        #expect(groups[0].title == nil)
        #expect(groups[0].books.count == 66)

        let names = groups[0].books.map(\.name)
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(names == sorted)
    }

    @Test("alphabetical order with a query stays a single sorted group")
    func alphabeticalWithQueryStaysSingleGroup() {
        let viewModel = makeViewModel()
        viewModel.order = .alphabetical
        viewModel.query = "samuel"
        #expect(viewModel.groups.count == 1)
        #expect(viewModel.groups[0].books.map(\.id) == ["1SA", "2SA"])
    }

    @Test("the current position auto-expands its book on open")
    func currentPositionAutoExpands() {
        let viewModel = makeViewModel(
            currentPosition: BiblePosition(bookId: "ROM", chapterNumber: 8)
        )
        #expect(viewModel.expandedBookId == "ROM")
    }

    @Test("a nil current position opens with every book collapsed")
    func nilCurrentPositionLeavesAllCollapsed() {
        let viewModel = makeViewModel(currentPosition: nil)
        #expect(viewModel.expandedBookId == nil)
        #expect(viewModel.initialScrollAnchor == nil)
    }

    @Test("a short-book position anchors on the book name row")
    func shortBookAnchorsOnBookRow() {
        let viewModel = makeViewModel(
            currentPosition: BiblePosition(bookId: "ROM", chapterNumber: 8)
        )
        #expect(viewModel.initialScrollAnchor == .bookRow(bookId: "ROM"))
    }

    @Test("a long-book late-chapter position anchors on the chapter cell")
    func longBookLateChapterAnchorsOnChapterCell() {
        let viewModel = makeViewModel(
            currentPosition: BiblePosition(bookId: "PSA", chapterNumber: 119)
        )
        #expect(
            viewModel.initialScrollAnchor
                == .chapterCell(bookId: "PSA", chapterNumber: 119)
        )
    }

    @Test("chapter 48 still anchors on the book name row")
    func boundaryChapter48AnchorsOnBookRow() {
        let viewModel = makeViewModel(
            currentPosition: BiblePosition(bookId: "PSA", chapterNumber: 48)
        )
        #expect(viewModel.initialScrollAnchor == .bookRow(bookId: "PSA"))
    }

    @Test("chapter 49 crosses into chapter-cell anchoring")
    func boundaryChapter49AnchorsOnChapterCell() {
        let viewModel = makeViewModel(
            currentPosition: BiblePosition(bookId: "PSA", chapterNumber: 49)
        )
        #expect(
            viewModel.initialScrollAnchor
                == .chapterCell(bookId: "PSA", chapterNumber: 49)
        )
    }

    @Test("toggling expansion opens one book and closes it on a repeat tap")
    func expansionToggles() {
        let viewModel = makeViewModel(
            currentPosition: BiblePosition(bookId: "1PE", chapterNumber: 1)
        )
        #expect(viewModel.expandedBookId == "1PE")

        viewModel.toggleExpansion(bookId: "ROM")
        #expect(viewModel.expandedBookId == "ROM")

        viewModel.toggleExpansion(bookId: "ROM")
        #expect(viewModel.expandedBookId == nil)
    }

    @Test("the expanded book survives a search that filters it out")
    func expansionPersistsAcrossSearch() {
        let viewModel = makeViewModel(
            currentPosition: BiblePosition(bookId: "1PE", chapterNumber: 1)
        )
        viewModel.query = "genesis"                     // 1 Peter no longer in the list
        #expect(viewModel.expandedBookId == "1PE")

        viewModel.clearQuery()
        #expect(viewModel.expandedBookId == "1PE")
    }

    @Test("clearing the query empties it")
    func clearQueryEmptiesQuery() {
        let viewModel = makeViewModel()
        viewModel.query = "psa"
        viewModel.clearQuery()
        #expect(viewModel.query.isEmpty)
    }
}
