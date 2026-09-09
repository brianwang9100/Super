import Foundation

public struct ChapterRef: Hashable, Sendable {
    public let bookID: String
    public let number: Int

    public init(bookID: String, number: Int) {
        self.bookID = bookID
        self.number = number
    }
}

/// Whole-book selection means every chapter is present in its set.
public struct BulkSelection: Sendable, Equatable {
    public private(set) var chapters: [String: Set<Int>]

    public init(chapters: [String: Set<Int>] = [:]) {
        self.chapters = chapters.filter { !$0.value.isEmpty }
    }

    public func selectedChapters(in bookID: String) -> Set<Int> { chapters[bookID] ?? [] }

    public func isChapterSelected(_ ref: ChapterRef) -> Bool {
        chapters[ref.bookID]?.contains(ref.number) ?? false
    }

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

    public mutating func toggleBook(_ bookID: String, chapterCount: Int) {
        if bookSelectionState(bookID, chapterCount: chapterCount) == .full {
            chapters[bookID] = nil
        } else {
            chapters[bookID] = Set(1...max(1, chapterCount))
        }
    }

    public var selectedChapterCount: Int { chapters.values.reduce(0) { $0 + $1.count } }

    public var selectedBookCount: Int { chapters.count }

    public var isEmpty: Bool { chapters.isEmpty }

    public enum BookSelectionState: Sendable, Equatable { case none, partial, full }
}

/// Rough pre-run estimate. Throughput is a placeholder requiring calibration against real models.
public struct BulkRunEstimate: Sendable, Equatable {
    public let books: Int
    public let annotations: Int
    public let minutes: Int

    public static let annotationsPerChapter = 1
    /// Prompted soft cap used only for estimates; actual notable-verse count varies.
    public static let notableVersesPerChapter = 5
    public static let secondsPerChapter = 3

    public init(selection: BulkSelection, includesNotableVerses: Bool = false) {
        let chapters = selection.selectedChapterCount
        books = selection.selectedBookCount
        let perChapter = Self.annotationsPerChapter
            + (includesNotableVerses ? Self.notableVersesPerChapter : 0)
        annotations = chapters * perChapter
        // Time scales with estimated annotation count, including notable ranges.
        minutes = max(1, Int((Double(chapters * perChapter * Self.secondsPerChapter) / 60).rounded(.up)))
    }
}
