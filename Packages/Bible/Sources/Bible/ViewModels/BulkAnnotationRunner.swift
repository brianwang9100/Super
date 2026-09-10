import Foundation

public struct BulkRunPlan: Sendable, Equatable {
    public struct Book: Sendable, Equatable {
        public let bookID: String
        public let name: String
        public let chapters: [Int]
        /// Adds a book-level annotation before chapters for whole-book selections.
        public let includesBookLevel: Bool
        public init(bookID: String, name: String, chapters: [Int], includesBookLevel: Bool = false) {
            self.bookID = bookID
            self.name = name
            self.chapters = chapters
            self.includesBookLevel = includesBookLevel
        }
    }

    public let books: [Book]

    /// False preserves existing target slots without generation; true replaces them.
    public let overwriteExisting: Bool

    /// Adds one notable-verse dispatch per chapter alongside its summary.
    public let includesNotableVerses: Bool

    public init(books: [Book], overwriteExisting: Bool = false, includesNotableVerses: Bool = false) {
        self.books = books
        self.overwriteExisting = overwriteExisting
        self.includesNotableVerses = includesNotableVerses
    }

    public var isEmpty: Bool { books.allSatisfy { $0.chapters.isEmpty } }
}

/// One active job; onSnapshotChange tells the view model to reread the snapshot.
@MainActor
public protocol BulkAnnotationRunning: AnyObject {
    /// Nil while idle; includes both running and paused jobs.
    var snapshot: BulkRunSnapshot? { get }
    var onSnapshotChange: (@MainActor @Sendable () -> Void)? { get set }

    func start(_ plan: BulkRunPlan)
    func togglePause()
    func retry(_ ref: ChapterRef)
    func retryAllFailed()
    func cancel()

    /// Revives failed work in a terminal run; no-op while another run is active or for a nonterminal ID.
    func resume(runID: String)
    /// No-op for the active run; cancel it through cancel() instead.
    func dismissFinishedRun(id: String)
}
