import Foundation

/// In-memory stand-in for the real bulk-annotation engine. Drives realistic
/// `queued → generating → done` (and a seeded `failed`) transitions so the hub,
/// job card, and per-book progress are fully interactive, previewable, and
/// snapshot-testable before the LLM-backed runner exists.
///
/// `autoAdvance` runs the simulation on a timer for previews / the simulator.
/// Tests construct it with `autoAdvance: false` and call `step()` to advance
/// deterministically (no sleeps), per the project's async-test rules.
@MainActor
public final class FakeBulkAnnotationRunner: BulkAnnotationRunning {
    public private(set) var snapshot: BulkRunSnapshot?
    public var onSnapshotChange: (() -> Void)?

    private let autoAdvance: Bool
    private let stepInterval: Duration
    /// Chapters seeded to fail the first time they generate (then they succeed
    /// on a manual retry). Used to demo the partial-failure state.
    private var failOnce: Set<ChapterRef>
    private var driver: Task<Void, Never>?

    public init(
        autoAdvance: Bool = true,
        stepInterval: Duration = .milliseconds(700),
        failOnce: Set<ChapterRef> = []
    ) {
        self.autoAdvance = autoAdvance
        self.stepInterval = stepInterval
        self.failOnce = failOnce
    }

    /// Seed a snapshot directly — lets previews/tests render a specific mid-run
    /// or partial-failure state without stepping there.
    public func seed(_ snapshot: BulkRunSnapshot) {
        self.snapshot = snapshot
        notify()
    }

    public func start(_ plan: BulkRunPlan) {
        let firstBookID = plan.books.first?.bookID
        var books: [BulkBookProgress] = []
        for book in plan.books {
            var chapterRows: [BulkChapterProgress] = []
            for (index, number) in book.chapters.enumerated() {
                // The first chapter of the first book starts generating.
                let isFirstUnit = index == 0 && book.bookID == firstBookID
                let state: BulkUnitState = isFirstUnit ? .generating : .queued
                chapterRows.append(
                    BulkChapterProgress(number: number, state: state, producedCount: Self.noteCount(number))
                )
            }
            books.append(BulkBookProgress(bookID: book.bookID, name: book.name, chapters: chapterRows))
        }
        snapshot = BulkRunSnapshot(books: books, isRunning: true)
        notify()
        startDriverIfNeeded()
    }

    public func togglePause() {
        guard var snap = snapshot else { return }
        snap.isRunning.toggle()
        snapshot = snap
        notify()
        if snap.isRunning { startDriverIfNeeded() } else { driver?.cancel(); driver = nil }
    }

    public func retry(_ ref: ChapterRef) {
        failOnce.remove(ref)
        mutateChapter(ref) { $0.state = .generating }
        startDriverIfNeeded()
    }

    public func retryAllFailed() {
        guard var snap = snapshot else { return }
        for b in snap.books.indices {
            for c in snap.books[b].chapters.indices where snap.books[b].chapters[c].state == .failed {
                let ref = ChapterRef(bookID: snap.books[b].bookID, number: snap.books[b].chapters[c].number)
                failOnce.remove(ref)
                snap.books[b].chapters[c].state = .queued
            }
        }
        snap.isRunning = true
        snapshot = snap
        notify()
        promoteNextQueuedToGenerating()
        startDriverIfNeeded()
    }

    public func cancel() {
        driver?.cancel(); driver = nil
        snapshot = nil
        notify()
    }

    /// Advance the simulation by one unit. Finishes the current generating
    /// chapter (done, or failed if seeded), then promotes the next queued one.
    /// Returns `false` when nothing is left to do.
    @discardableResult
    public func step() -> Bool {
        guard var snap = snapshot, snap.isRunning else { return false }
        var changed = false
        outer: for b in snap.books.indices {
            for c in snap.books[b].chapters.indices where snap.books[b].chapters[c].state == .generating {
                let ref = ChapterRef(bookID: snap.books[b].bookID, number: snap.books[b].chapters[c].number)
                snap.books[b].chapters[c].state = failOnce.contains(ref) ? .failed : .done
                changed = true
                break outer
            }
        }
        snapshot = snap
        if changed { notify() }
        let promoted = promoteNextQueuedToGenerating()
        return changed || promoted
    }

    // MARK: - Private

    @discardableResult
    private func promoteNextQueuedToGenerating() -> Bool {
        guard var snap = snapshot else { return false }
        // Don't run a second unit while one is already generating.
        let anyGenerating = snap.books.contains { $0.chapters.contains { $0.state == .generating } }
        if anyGenerating { return false }
        for b in snap.books.indices {
            for c in snap.books[b].chapters.indices where snap.books[b].chapters[c].state == .queued {
                snap.books[b].chapters[c].state = .generating
                snapshot = snap
                notify()
                return true
            }
        }
        return false
    }

    private func startDriverIfNeeded() {
        guard autoAdvance, driver == nil else { return }
        driver = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.stepInterval else { return }
                try? await Task.sleep(for: interval)
                guard let self, self.snapshot?.isRunning == true else { return }
                if !self.step() { self.driver = nil; return }
            }
        }
    }

    private func mutateChapter(_ ref: ChapterRef, _ transform: (inout BulkChapterProgress) -> Void) {
        guard var snap = snapshot else { return }
        for b in snap.books.indices where snap.books[b].bookID == ref.bookID {
            for c in snap.books[b].chapters.indices where snap.books[b].chapters[c].number == ref.number {
                transform(&snap.books[b].chapters[c])
            }
        }
        snapshot = snap
        notify()
    }

    private func notify() { onSnapshotChange?() }

    /// Deterministic per-chapter annotation count (matches the design's
    /// hand-picked spread so previews read naturally).
    private static func noteCount(_ n: Int) -> Int {
        let bank = [9, 14, 11, 16, 12, 8, 13, 18, 10, 15, 7, 12, 9, 11, 14, 6]
        return bank[(n - 1) % bank.count]
    }
}
