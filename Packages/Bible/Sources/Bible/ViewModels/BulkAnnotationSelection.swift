import Foundation

/// A single chapter address used across the bulk-annotation selection and
/// "already annotated" sets.
public struct ChapterRef: Hashable, Sendable {
    public let bookID: String
    public let number: Int

    public init(bookID: String, number: Int) {
        self.bookID = bookID
        self.number = number
    }
}

/// What the user has picked in the Generate sheet: the set of selected chapter
/// numbers per book. Whole-book selection is represented as every chapter of
/// that book being present. Pure value type so the toggle rules and the
/// estimate are unit-testable without a view.
public struct BulkSelection: Sendable, Equatable {
    /// bookID → selected chapter numbers.
    public private(set) var chapters: [String: Set<Int>]

    public init(chapters: [String: Set<Int>] = [:]) {
        self.chapters = chapters.filter { !$0.value.isEmpty }
    }

    public func selectedChapters(in bookID: String) -> Set<Int> { chapters[bookID] ?? [] }

    public func isChapterSelected(_ ref: ChapterRef) -> Bool {
        chapters[ref.bookID]?.contains(ref.number) ?? false
    }

    /// `.full` when every chapter of `chapterCount` is selected, `.partial`
    /// when some are, `.none` when none.
    public func bookSelectionState(_ bookID: String, chapterCount: Int) -> BookSelectionState {
        let selected = selectedChapters(in: bookID)
        if selected.isEmpty { return .none }
        if selected.count >= chapterCount { return .full }
        return .partial
    }

    public mutating func toggleChapter(_ ref: ChapterRef) {
        var set = chapters[ref.bookID] ?? []
        if set.contains(ref.number) { set.remove(ref.number) } else { set.insert(ref.number) }
        if set.isEmpty { chapters[ref.bookID] = nil } else { chapters[ref.bookID] = set }
    }

    /// Toggle the whole book: select every chapter when not already full,
    /// otherwise clear it.
    public mutating func toggleBook(_ bookID: String, chapterCount: Int) {
        if bookSelectionState(bookID, chapterCount: chapterCount) == .full {
            chapters[bookID] = nil
        } else {
            chapters[bookID] = Set(1...max(1, chapterCount))
        }
    }

    /// Total selected chapters across all books.
    public var selectedChapterCount: Int { chapters.values.reduce(0) { $0 + $1.count } }

    /// Books with at least one selected chapter.
    public var selectedBookCount: Int { chapters.count }

    public var isEmpty: Bool { chapters.isEmpty }

    public enum BookSelectionState: Sendable, Equatable { case none, partial, full }
}

/// A rough pre-run estimate for the Generate sheet footer. **Placeholder
/// throughput** — `annotationsPerChapter` and `secondsPerChapter` want tuning
/// to real model speed (flagged in the design handoff).
public struct BulkRunEstimate: Sendable, Equatable {
    public let books: Int
    public let annotations: Int
    public let minutes: Int

    /// Annotations a chapter's summary yields — exactly one since the
    /// single-summary redesign (`bible.annotate` writes one markdown
    /// summary per target). Kept as a named constant so the footer
    /// estimate's derivation stays explicit.
    public static let annotationsPerChapter = 1
    /// Upper bound on notable-verse annotations a chapter yields when the
    /// run opts into notable verses — the soft cap the dispatcher prompts the
    /// model with. Used only for the footer estimate; the real count varies.
    public static let notableVersesPerChapter = 5
    public static let secondsPerChapter = 3

    public init(selection: BulkSelection, includesNotableVerses: Bool = false) {
        let chapters = selection.selectedChapterCount
        books = selection.selectedBookCount
        let perChapter = Self.annotationsPerChapter
            + (includesNotableVerses ? Self.notableVersesPerChapter : 0)
        annotations = chapters * perChapter
        // Rough proxy: scale the time with the total annotation count (the
        // notable-verse turn writes several rows in one dispatch, but it also
        // takes proportionally longer, so per-annotation seconds stays a fair
        // upper-ish estimate).
        minutes = max(1, Int((Double(chapters * perChapter * Self.secondsPerChapter) / 60).rounded(.up)))
    }
}
