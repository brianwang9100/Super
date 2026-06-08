import Core
import Testing
@testable import Bible

/// Focused tests for `BulkAnnotationViewModel`'s derived state — specifically the
/// "Done" badge folding, where a book counts as done only when *every* one of its
/// chapters carries an annotation.
@MainActor
@Suite struct BulkAnnotationViewModelTests {
    private func makeViewModel() -> BulkAnnotationViewModel {
        BulkAnnotationViewModel(runner: FakeBulkAnnotationRunner(autoAdvance: false))
    }

    @Test func updateDoneStateMarksChaptersAndFullyAnnotatedBooks() {
        let vm = makeViewModel()
        vm.updateDoneState(annotatedChapters: [
            ChapterRef(bookID: "PHM", number: 1),  // Philemon — its only chapter
            ChapterRef(bookID: "ROM", number: 1),  // one of Romans' 16
        ])

        // Per-chapter badges reflect the raw set.
        #expect(vm.chapterDone(ChapterRef(bookID: "PHM", number: 1)))
        #expect(vm.chapterDone(ChapterRef(bookID: "ROM", number: 1)))
        #expect(!vm.chapterDone(ChapterRef(bookID: "ROM", number: 2)))

        // A one-chapter book fully covered is done; a partially covered book isn't.
        #expect(vm.bookDone("PHM"))
        #expect(!vm.bookDone("ROM"))
    }

    @Test func updateDoneStateMarksAMultiChapterBookDoneWhenFullyCovered() {
        let vm = makeViewModel()
        // 2 John has a single chapter; cover it and the book is done.
        vm.updateDoneState(annotatedChapters: [ChapterRef(bookID: "2JN", number: 1)])
        #expect(vm.bookDone("2JN"))

        // Clearing the set clears every badge.
        vm.updateDoneState(annotatedChapters: [])
        #expect(!vm.bookDone("2JN"))
        #expect(vm.annotatedChapters.isEmpty)
        #expect(vm.fullyAnnotatedBookIDs.isEmpty)
    }

    // MARK: - generate() resolves whole-book selections to book-level generation

    /// Linear lookup instead of `.first(where:)` — predicate closures inside a
    /// `@MainActor` test body can SIGTRAP under `swift test` on macOS.
    private func planBook(_ plan: BulkRunPlan, bookID: String) -> BulkRunPlan.Book? {
        for book in plan.books where book.bookID == bookID { return book }
        return nil
    }

    private func catalogBook(_ vm: BulkAnnotationViewModel, id: String) -> BibleBookSummary? {
        for book in vm.books where book.id == id { return book }
        return nil
    }

    @Test func generateFlagsAFullySelectedBookForBookLevelGeneration() throws {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        let vm = BulkAnnotationViewModel(runner: runner)
        // Philemon has a single chapter, so selecting it is a whole-book pick.
        let philemon = try #require(catalogBook(vm, id: "PHM"))
        vm.toggleBook(philemon)

        vm.generate()

        let plan = try #require(runner.startedPlans.first)
        let book = try #require(planBook(plan, bookID: "PHM"))
        #expect(book.includesBookLevel)
    }

    @Test func generateDoesNotFlagAPartiallySelectedBook() throws {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        let vm = BulkAnnotationViewModel(runner: runner)
        // Romans has 16 chapters — pick just one, a partial selection.
        vm.toggleChapter(ChapterRef(bookID: "ROM", number: 1))

        vm.generate()

        let plan = try #require(runner.startedPlans.first)
        let book = try #require(planBook(plan, bookID: "ROM"))
        #expect(!book.includesBookLevel)
    }

    @Test func generateThreadsTheOverwriteFlagIntoThePlan() throws {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        let vm = BulkAnnotationViewModel(runner: runner)
        vm.toggleChapter(ChapterRef(bookID: "ROM", number: 1))
        vm.overwriteExisting = true

        vm.generate()

        let plan = try #require(runner.startedPlans.first)
        #expect(plan.overwriteExisting)
    }

    @Test func generateDefaultsToPreserveWhenTheToggleIsOff() throws {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        let vm = BulkAnnotationViewModel(runner: runner)
        vm.toggleChapter(ChapterRef(bookID: "ROM", number: 1))

        vm.generate()

        let plan = try #require(runner.startedPlans.first)
        #expect(!plan.overwriteExisting)
    }

    // MARK: - confirmDeleteAll drives the injected closure

    @Test func confirmDeleteAllInvokesTheInjectedClosure() {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        let box = DeleteAllSpy()
        let vm = BulkAnnotationViewModel(runner: runner, deleteAll: { box.calls += 1 })

        vm.confirmDeleteAll()

        #expect(box.calls == 1)
    }
}

/// Reference box so the `deleteAll` closure can record invocations without
/// capturing a mutable local.
@MainActor private final class DeleteAllSpy { var calls = 0 }
