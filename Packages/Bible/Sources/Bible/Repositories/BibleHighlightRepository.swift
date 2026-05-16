import Foundation

/// Writes the reader's verse highlights.
///
/// Protocol-typed so the view model depends on the seam, not GRDB. Reads are
/// deliberately absent: the chapter renderer observes highlights reactively
/// through GRDBQuery's `@Query` (`ChapterHighlightsRequest`), so the only
/// imperative path is the action sheet's writes.
public protocol BibleHighlightRepository: Sendable {
    /// Highlight a verse, or recolour it if it is already highlighted.
    ///
    /// At most one row per `(bookId, chapterNumber, verseNumber)` ever exists:
    /// a verse already carrying a highlight — active or cleared — is updated in
    /// place, so re-highlighting a cleared verse restores its original row.
    func setHighlight(
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        color: BibleHighlightColor,
        at now: Date
    ) async throws

    /// Clear a verse's highlight by soft-deleting its row. A no-op when the
    /// verse is not highlighted.
    func clearHighlight(
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        at now: Date
    ) async throws
}
