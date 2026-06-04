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
}
