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
    /// Preserve mode: an annotation already occupied this unit's target slot, so
    /// the runner skipped it without an LLM call. Terminal — counted as neither
    /// produced nor failed.
    case skipped
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

    /// Fraction of chapters that have reached a terminal state (done, failed, or
    /// skipped). A skipped chapter is finished work — it counts toward the ring.
    public var fractionComplete: Double {
        guard !chapters.isEmpty else { return 0 }
        let terminal = chapters.filter {
            $0.state == .done || $0.state == .failed || $0.state == .skipped
        }.count
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

/// A finished run as the hub's "Recently finished" section reads it — a flat
/// projection of one terminal `bulkAnnotationRun` plus its units, built by
/// `FinishedRunsRequest`. The active `BulkRunSnapshot` covers the *running* job;
/// once a run goes terminal it clears from the snapshot and surfaces here
/// instead (until the 24 h sweep or a manual dismiss removes it).
public struct FinishedRunSummary: Sendable, Equatable, Identifiable {
    public let runID: String
    /// The terminal status (`.completed` or `.failed`; cancelled runs are not
    /// listed — they were a deliberate user abort).
    public let status: BulkRunStatus
    /// Why the run halted, when `status == .failed`.
    public let haltReason: BulkRunHaltReason?
    /// Set on every terminal run — the section's newest-first sort key.
    public let completedAt: Date
    /// Distinct book display names in run order — the entry's title.
    public let bookNames: [String]
    /// Annotations written across every `.done` unit.
    public let producedCount: Int
    /// Units that exhausted their retries.
    public let failedCount: Int

    public var id: String { runID }

    public init(
        runID: String,
        status: BulkRunStatus,
        haltReason: BulkRunHaltReason?,
        completedAt: Date,
        bookNames: [String],
        producedCount: Int,
        failedCount: Int
    ) {
        self.runID = runID
        self.status = status
        self.haltReason = haltReason
        self.completedAt = completedAt
        self.bookNames = bookNames
        self.producedCount = producedCount
        self.failedCount = failedCount
    }

    /// `true` when the run still has revivable work (failed units, or a halt) —
    /// drives the entry's **Retry** affordance. A clean completion offers only
    /// dismiss.
    public var isRetryable: Bool { failedCount > 0 || status == .failed }
}
