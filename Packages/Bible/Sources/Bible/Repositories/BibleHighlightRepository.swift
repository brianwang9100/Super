import Foundation

public protocol BibleHighlightRepository: Sendable {
    /// Updates the existing row, including a cleared row, preserving its original identity.
    func setHighlight(
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        color: BibleHighlightColor,
        at now: Date
    ) async throws

    /// Soft-deletes; no-op if absent.
    func clearHighlight(
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        at now: Date
    ) async throws

    /// Absent or cleared verses have no entry.
    func activeHighlightColors(
        bookId: String,
        chapterNumber: Int,
        verseNumbers: [Int]
    ) async throws -> [Int: BibleHighlightColor]

    /// Active rows only, ordered by verse.
    func activeHighlights(
        bookId: String,
        chapterNumber: Int
    ) async throws -> [BibleHighlightRecord]

    /// Active rows ordered by book, chapter, verse; nil bookId searches all books.
    func activeHighlights(
        color: BibleHighlightColor,
        bookId: String?
    ) async throws -> [BibleHighlightRecord]
}
