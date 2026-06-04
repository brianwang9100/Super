import Foundation

/// A resolved bulk-annotation run: the ordered books and, per book, the
/// chapter numbers to generate. Built from a `BulkSelection` plus the catalog
/// (for display names). The real engine (follow-on PR) and the in-memory fake
/// both consume this.
public struct BulkRunPlan: Sendable, Equatable {
    public struct Book: Sendable, Equatable {
        public let bookID: String
        public let name: String
        public let chapters: [Int]
        public init(bookID: String, name: String, chapters: [Int]) {
            self.bookID = bookID
            self.name = name
            self.chapters = chapters
        }
    }

    public let books: [Book]

    public init(books: [Book]) { self.books = books }

    public var isEmpty: Bool { books.allSatisfy { $0.chapters.isEmpty } }
}

/// The seam the hub view model drives. One job at a time; the runner owns the
/// live `BulkRunSnapshot` and notifies the view model via `onSnapshotChange`
/// (the view model mirrors it into its own `@Observable` state). The real
/// `BulkAnnotationRunner` actor lands in a follow-on PR; this pass injects the
/// in-memory `FakeBulkAnnotationRunner`.
@MainActor
public protocol BulkAnnotationRunning: AnyObject {
    /// `nil` when idle; a snapshot while a job exists (running or paused).
    var snapshot: BulkRunSnapshot? { get }
    /// Called whenever `snapshot` changes so the view model re-reads. Marked
    /// `@MainActor @Sendable` so the real `BulkAnnotationRunner` actor (follow-on)
    /// can't invoke it without hopping to main first.
    var onSnapshotChange: (@MainActor @Sendable () -> Void)? { get set }

    func start(_ plan: BulkRunPlan)
    func togglePause()
    func retry(_ ref: ChapterRef)
    func retryAllFailed()
    func cancel()

    /// Re-adopt a finished run (from the hub's "Recently finished" list) as the
    /// active job: revive its failed units and resume generation. A no-op when a
    /// run is already active (one job at a time) or the id isn't a terminal run.
    func resume(runID: String)
    /// Remove a finished run from the ledger (the list's dismiss control). A
    /// no-op for the active run, which is torn down via `cancel()` instead.
    func dismissFinishedRun(id: String)
}
