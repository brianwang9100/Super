import Foundation

/// The lifecycle of one bulk-annotation **unit** (a chapter, or a book
/// prologue) as it moves through a run. Mirrors the design's chapter-row
/// vocabulary (`queued · gen · done · failed`) one-to-one so a row reads the
/// same as the reader's verse-end `AnnotationBubble`.
public enum BulkUnitState: String, Sendable, Equatable, Codable {
    /// Waiting its turn — nothing generated yet.
    case queued
    /// The active unit; an LLM request is in flight.
    case generating
    /// Finished; `producedCount` annotations were written (can be 0).
    case done
    /// Exhausted automatic retries — offered for manual retry.
    case failed
}

/// One chapter's progress within a running book. `producedCount` is the
/// number of annotations written so far (only meaningful once `.done`).
public struct BulkChapterProgress: Sendable, Equatable, Identifiable {
    public let number: Int
    public var state: BulkUnitState
    public var producedCount: Int

    public var id: Int { number }

    public init(number: Int, state: BulkUnitState, producedCount: Int = 0) {
        self.number = number
        self.state = state
        self.producedCount = producedCount
    }
}

/// One book inside the active run — its display name and per-chapter progress.
/// The per-book progress screen drills into one of these.
public struct BulkBookProgress: Sendable, Equatable, Identifiable {
    public let bookID: String
    public let name: String
    public var chapters: [BulkChapterProgress]

    public var id: String { bookID }

    public init(bookID: String, name: String, chapters: [BulkChapterProgress]) {
        self.bookID = bookID
        self.name = name
        self.chapters = chapters
    }

    /// Annotations written so far across this book's chapters.
    public var producedCount: Int {
        chapters.filter { $0.state == .done }.reduce(0) { $0 + $1.producedCount }
    }

    /// Best-effort total annotations once every chapter completes — used for
    /// the "X of ~Y annotations" headline (the `~` flags it as an estimate).
    public var estimatedTotal: Int {
        chapters.reduce(0) { $0 + $1.producedCount }
    }

    /// Fraction of chapters that have reached a terminal state (done or failed).
    public var fractionComplete: Double {
        guard !chapters.isEmpty else { return 0 }
        let terminal = chapters.filter { $0.state == .done || $0.state == .failed }.count
        return Double(terminal) / Double(chapters.count)
    }

    public var failedCount: Int {
        chapters.filter { $0.state == .failed }.count
    }
}

/// The single active job, as the hub's `JobCard` and the per-book progress
/// screen read it. There is **one job at a time**; the title lists every book
/// in the run and progress is measured in **annotations**, never chapters.
public struct BulkRunSnapshot: Sendable, Equatable {
    public var books: [BulkBookProgress]
    /// `true` while the runner is actively generating; `false` when paused.
    public var isRunning: Bool

    public init(books: [BulkBookProgress], isRunning: Bool = true) {
        self.books = books
        self.isRunning = isRunning
    }

    /// Book display names, in run order — the `JobCard` title.
    public var bookNames: [String] { books.map(\.name) }

    public var producedCount: Int { books.reduce(0) { $0 + $1.producedCount } }
    public var estimatedTotal: Int { books.reduce(0) { $0 + $1.estimatedTotal } }
    public var failedCount: Int { books.reduce(0) { $0 + $1.failedCount } }

    /// Annotation-based fraction (produced / estimated) — drives the hub's
    /// `JobCard` bar. Note this differs from `BulkBookProgress.fractionComplete`,
    /// which is *chapter*-based (terminal / total) and drives the per-book ring:
    /// the two agree at 0 and at all-done-no-failures, but diverge mid-run and
    /// under partial failure (a failed chapter keeps this bar below 1.0 while the
    /// ring, counting failed as terminal, can reach 1.0). The real engine should
    /// pick one denominator deliberately rather than inherit this split.
    public var fractionComplete: Double {
        guard estimatedTotal > 0 else { return 0 }
        return Double(producedCount) / Double(estimatedTotal)
    }
}
