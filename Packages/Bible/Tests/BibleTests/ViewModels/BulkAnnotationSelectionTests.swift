import Testing
@testable import Bible

/// Tests for `BulkSelection` (the Generate-sheet picking model) and
/// `BulkRunEstimate` (the footer estimate) — pure value logic, no view.
@Suite("BulkAnnotationSelection")
struct BulkAnnotationSelectionTests {
    @Test("toggling a chapter adds then removes it")
    func toggleChapter() {
        var sel = BulkSelection()
        let ref = ChapterRef(bookID: "ROM", number: 8)
        sel.toggleChapter(ref)
        #expect(sel.isChapterSelected(ref))
        #expect(sel.selectedChapterCount == 1)
        sel.toggleChapter(ref)
        #expect(!sel.isChapterSelected(ref))
        #expect(sel.isEmpty)
    }

    @Test("toggling a whole book selects every chapter, then clears it")
    func toggleBook() {
        var sel = BulkSelection()
        sel.toggleBook("ROM", chapterCount: 16)
        #expect(sel.bookSelectionState("ROM", chapterCount: 16) == .full)
        #expect(sel.selectedChapters(in: "ROM").count == 16)
        sel.toggleBook("ROM", chapterCount: 16)
        #expect(sel.bookSelectionState("ROM", chapterCount: 16) == .none)
    }

    @Test("a subset of chapters reports the partial state")
    func partialState() {
        var sel = BulkSelection()
        sel.toggleChapter(ChapterRef(bookID: "ROM", number: 1))
        sel.toggleChapter(ChapterRef(bookID: "ROM", number: 2))
        #expect(sel.bookSelectionState("ROM", chapterCount: 16) == .partial)
    }

    @Test("selecting the last missing chapter promotes a partial book to full")
    func partialBecomesFull() {
        var sel = BulkSelection()
        for n in 1...3 { sel.toggleChapter(ChapterRef(bookID: "JUD", number: n)) }
        // Jude has a single chapter in reality; use a 3-chapter stand-in here.
        #expect(sel.bookSelectionState("JUD", chapterCount: 3) == .full)
    }

    @Test("book and chapter tallies count across multiple books")
    func tallies() {
        var sel = BulkSelection()
        sel.toggleBook("ROM", chapterCount: 16)
        sel.toggleChapter(ChapterRef(bookID: "GAL", number: 1))
        #expect(sel.selectedBookCount == 2)
        #expect(sel.selectedChapterCount == 17)
    }

    @Test("estimate scales with selected chapters and reports book count")
    func estimate() {
        var sel = BulkSelection()
        sel.toggleBook("ROM", chapterCount: 16)
        let est = BulkRunEstimate(selection: sel)
        #expect(est.books == 1)
        #expect(est.annotations == 16 * BulkRunEstimate.annotationsPerChapter)
        #expect(est.minutes >= 1)
    }

    @Test("an empty selection still yields at least a one-minute floor")
    func emptyEstimateFloor() {
        let est = BulkRunEstimate(selection: BulkSelection())
        #expect(est.books == 0)
        #expect(est.annotations == 0)
        #expect(est.minutes == 1)
    }

    @Test("notable verses add the per-chapter verse budget to the estimate")
    func estimateWithNotableVerses() {
        var sel = BulkSelection()
        sel.toggleBook("ROM", chapterCount: 16)
        let est = BulkRunEstimate(selection: sel, includesNotableVerses: true)
        let perChapter = BulkRunEstimate.annotationsPerChapter + BulkRunEstimate.notableVersesPerChapter
        #expect(est.annotations == 16 * perChapter)
    }
}
