import Foundation
import Observation

/// Drives the Settings → Annotations surfaces: the hub (coverage + job), the
/// Generate sheet (book/chapter selection + estimate), and per-book progress.
///
/// Coverage is read separately by the hub view via a GRDBQuery `@Query`
/// (`AnnotationCoverageRequest`) — it's a pure DB projection, so it doesn't live
/// here. This view model owns the run snapshot (mirrored from the injected
/// `BulkAnnotationRunning`) and the in-flight selection draft, which merge
/// DB-derived "done" state with non-persisted picking — exactly the imperative
/// case the root guidance carves out from reactive `@Query`.
@MainActor
@Observable
public final class BulkAnnotationViewModel {
    /// Live snapshot of the single active job, mirrored from the runner.
    public private(set) var run: BulkRunSnapshot?

    /// The Generate sheet's draft selection.
    public var selection = BulkSelection()
    /// Books expanded to reveal chapters in the Generate sheet.
    public var expandedBookIDs: Set<String> = []

    /// Chapters that already carry annotations — drives the "Done" badges.
    /// Injected from a query (or a fake in previews); empty by default.
    public var annotatedChapters: Set<ChapterRef> = []
    /// Books fully annotated across every chapter — book-level "Done" badge.
    public var fullyAnnotatedBookIDs: Set<String> = []

    public let catalog: BibleBookCatalog

    private let runner: any BulkAnnotationRunning
    private let deleteAll: () -> Void

    public init(
        runner: any BulkAnnotationRunning,
        catalog: BibleBookCatalog = .standard,
        deleteAll: @escaping () -> Void = {}
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
    public var estimate: BulkRunEstimate { BulkRunEstimate(selection: selection) }
    public var canGenerate: Bool { !selection.isEmpty && !isRunning }

    /// The book the per-book progress screen drills into: the one with work in
    /// flight, else the first.
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

    /// `true` when every chapter of every book is selected.
    public var isAllSelected: Bool {
        catalog.books.allSatisfy {
            selection.bookSelectionState($0.id, chapterCount: $0.chapterCount) == .full
        }
    }

    public var isAnySelected: Bool { !selection.isEmpty }

    /// Select every chapter of every book, or clear the whole selection if it's
    /// already complete. Does not expand the books in the picker.
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

    /// Resolve the draft selection into a plan and start the single job.
    public func generate() {
        guard !selection.isEmpty else { return }
        let books: [BulkRunPlan.Book] = catalog.books.compactMap { summary in
            let chapters = selection.selectedChapters(in: summary.id).sorted()
            guard !chapters.isEmpty else { return nil }
            return BulkRunPlan.Book(bookID: summary.id, name: summary.name, chapters: chapters)
        }
        guard !books.isEmpty else { return }
        runner.start(BulkRunPlan(books: books))
        selection = BulkSelection()
        expandedBookIDs = []
    }

    public func togglePause() { runner.togglePause() }
    public func retry(_ ref: ChapterRef) { runner.retry(ref) }
    public func retryAllFailed() { runner.retryAllFailed() }
    public func cancelRun() { runner.cancel() }
    public func confirmDeleteAll() { deleteAll() }

    // MARK: - Finished-run intents

    /// Re-adopt a finished run as the active job (the list's Retry control).
    public func retryFinishedRun(_ runID: String) { runner.resume(runID: runID) }

    /// Remove a finished run from the list (its dismiss control).
    public func dismissFinishedRun(_ runID: String) { runner.dismissFinishedRun(id: runID) }

    // MARK: - Done-badge state

    /// Fold the annotated-chapters query result into the per-chapter and
    /// per-book "Done" badges. A book is done when *every* chapter it has carries
    /// an annotation (derived against the catalog's chapter counts). Called by
    /// the hub container whenever the `@Query` value changes.
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
