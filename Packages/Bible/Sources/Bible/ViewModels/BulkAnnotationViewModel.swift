import Foundation
import Observation

/// Merges transient selection with query-derived done state; coverage remains a direct query binding.
@MainActor
@Observable
public final class BulkAnnotationViewModel {
    public private(set) var run: BulkRunSnapshot?

    public var selection = BulkSelection()
    public var expandedBookIDs: Set<String> = []
    /// Preserve/overwrite choice remains sticky across sheet openings.
    public var overwriteExisting = false
    /// Notable-verse choice remains sticky across sheet openings.
    public var annotateNotableVerses = false

    public var annotatedChapters: Set<ChapterRef> = []
    public var fullyAnnotatedBookIDs: Set<String> = []

    public let catalog: BibleBookCatalog

    private let runner: any BulkAnnotationRunning
    private let deleteAll: @MainActor () -> Void

    public init(
        runner: any BulkAnnotationRunning,
        catalog: BibleBookCatalog = .standard,
        deleteAll: @escaping @MainActor () -> Void = {}
    ) {
        self.runner = runner
        self.catalog = catalog
        self.deleteAll = deleteAll
        self.run = runner.snapshot
        runner.onSnapshotChange = { [weak self] in
            guard let self else { return }
            self.run = self.runner.snapshot
        }
    }

    // MARK: - Derived

    public var books: [BibleBookSummary] { catalog.books }
    public var isRunning: Bool { run != nil }
    public var estimate: BulkRunEstimate {
        BulkRunEstimate(selection: selection, includesNotableVerses: annotateNotableVerses)
    }
    public var canGenerate: Bool { !selection.isEmpty && !isRunning }

    public var activeBook: BulkBookProgress? {
        run?.books.first { $0.chapters.contains { $0.state == .generating || $0.state == .queued } }
            ?? run?.books.first
    }

    public func isExpanded(_ bookID: String) -> Bool { expandedBookIDs.contains(bookID) }

    public func bookDone(_ bookID: String) -> Bool { fullyAnnotatedBookIDs.contains(bookID) }

    public func chapterDone(_ ref: ChapterRef) -> Bool { annotatedChapters.contains(ref) }

    // MARK: - Selection intents

    public func toggleExpand(_ bookID: String) {
        if expandedBookIDs.contains(bookID) { expandedBookIDs.remove(bookID) }
        else { expandedBookIDs.insert(bookID) }
    }

    public func toggleBook(_ summary: BibleBookSummary) {
        selection.toggleBook(summary.id, chapterCount: summary.chapterCount)
    }

    public func toggleChapter(_ ref: ChapterRef) {
        selection.toggleChapter(ref)
    }

    public var isAllSelected: Bool {
        catalog.books.allSatisfy {
            selection.bookSelectionState($0.id, chapterCount: $0.chapterCount) == .full
        }
    }

    public var isAnySelected: Bool { !selection.isEmpty }

    /// Selects or clears all chapters without expanding books.
    public func toggleSelectAll() {
        if isAllSelected {
            selection = BulkSelection()
        } else {
            var chapters: [String: Set<Int>] = [:]
            for book in catalog.books {
                chapters[book.id] = Set(1...book.chapterCount)
            }
            selection = BulkSelection(chapters: chapters)
        }
    }

    // MARK: - Run intents

    public func generate() {
        guard !selection.isEmpty else { return }
        let books: [BulkRunPlan.Book] = catalog.books.compactMap { summary in
            let chapters = selection.selectedChapters(in: summary.id).sorted()
            guard !chapters.isEmpty else { return nil }
            let isWholeBook = selection.bookSelectionState(
                summary.id, chapterCount: summary.chapterCount
            ) == .full
            return BulkRunPlan.Book(
                bookID: summary.id,
                name: summary.name,
                chapters: chapters,
                includesBookLevel: isWholeBook
            )
        }
        guard !books.isEmpty else { return }
        runner.start(BulkRunPlan(
            books: books,
            overwriteExisting: overwriteExisting,
            includesNotableVerses: annotateNotableVerses
        ))
        selection = BulkSelection()
        expandedBookIDs = []
    }

    public func togglePause() { runner.togglePause() }
    public func retry(_ ref: ChapterRef) { runner.retry(ref) }
    public func retryAllFailed() { runner.retryAllFailed() }
    public func cancelRun() { runner.cancel() }
    public func confirmDeleteAll() { deleteAll() }

    // MARK: - Finished-run intents

    public func retryFinishedRun(_ runID: String) { runner.resume(runID: runID) }

    public func dismissFinishedRun(_ runID: String) { runner.dismissFinishedRun(id: runID) }

    // MARK: - Done-badge state

    /// A book is done only when every catalog chapter has an annotation.
    public func updateDoneState(annotatedChapters: Set<ChapterRef>) {
        self.annotatedChapters = annotatedChapters
        var fully: Set<String> = []
        for book in catalog.books where book.chapterCount > 0 {
            let allAnnotated = (1...book.chapterCount).allSatisfy {
                annotatedChapters.contains(ChapterRef(bookID: book.id, number: $0))
            }
            if allAnnotated { fully.insert(book.id) }
        }
        fullyAnnotatedBookIDs = fully
    }
}
