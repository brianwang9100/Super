import Foundation

/// Reads and writes the reader's verse highlights.
///
/// Protocol-typed so the view model depends on the seam, not GRDB. Chapter
/// *rendering* observes highlights reactively through GRDBQuery's `@Query`
/// (`ChapterHighlightsRequest`); the one imperative read here backs the action
/// sheet's toggle decision (re-tapping a verse's current colour clears it),
/// which needs the present state at tap time, not an ongoing observation.
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

    /// The active highlight colours for `verseNumbers`, keyed by verse number.
    /// Verses with no active highlight are absent from the result — so an empty
    /// map means none of the given verses are highlighted.
    func activeHighlightColors(
        bookId: String,
        chapterNumber: Int,
        verseNumbers: [Int]
    ) async throws -> [Int: BibleHighlightColor]
}
