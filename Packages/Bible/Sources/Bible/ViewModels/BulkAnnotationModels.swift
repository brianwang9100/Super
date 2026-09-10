import Foundation

public enum BulkUnitState: String, Sendable, Equatable, Codable {
    case queued
    case generating
    /// Done may produce zero annotations.
    case done
    /// Automatic retries exhausted; eligible for manual retry.
    case failed
    /// Existing annotations skipped without generation; terminal but neither produced nor failed.
    case skipped
}

/// producedCount is meaningful once done.
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

    public var producedCount: Int {
        chapters.filter { $0.state == .done }.reduce(0) { $0 + $1.producedCount }
    }

    /// Best-effort estimate used by the annotation-count headline.
    public var estimatedTotal: Int {
        chapters.reduce(0) { $0 + $1.producedCount }
    }

    /// Fraction of terminal chapters, including failed and skipped chapters.
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

public struct BulkRunSnapshot: Sendable, Equatable {
    public var books: [BulkBookProgress]
    public var isRunning: Bool

    public init(books: [BulkBookProgress], isRunning: Bool = true) {
        self.books = books
        self.isRunning = isRunning
    }

    public var bookNames: [String] { books.map(\.name) }

    public var producedCount: Int { books.reduce(0) { $0 + $1.producedCount } }
    public var estimatedTotal: Int { books.reduce(0) { $0 + $1.estimatedTotal } }
    public var failedCount: Int { books.reduce(0) { $0 + $1.failedCount } }

    /// Annotation produced/estimated fraction, unlike BulkBookProgress's terminal-chapter
    /// fraction. These can diverge during a run or after failures.
    public var fractionComplete: Double {
        guard estimatedTotal > 0 else { return 0 }
        return Double(producedCount) / Double(estimatedTotal)
    }
}

public struct FinishedRunSummary: Sendable, Equatable, Identifiable {
    public let runID: String
    /// Completed or failed; cancelled runs are excluded from history.
    public let status: BulkRunStatus
    public let haltReason: BulkRunHaltReason?
    public let completedAt: Date
    public let bookNames: [String]
    public let producedCount: Int
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

    public var isRetryable: Bool { failedCount > 0 || status == .failed }
}
