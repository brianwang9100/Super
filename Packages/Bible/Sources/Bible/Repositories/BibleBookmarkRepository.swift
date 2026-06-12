import Foundation

/// Reads and writes the six chapter-bookmark slots.
///
/// Protocol-typed so the view model depends on the seam, not GRDB. Every UI
/// surface *reads* bookmarks reactively through GRDBQuery (`@Query` over
/// `AllBookmarksRequest` / `ChapterBookmarkRequest`); this seam carries the
/// writes, plus one imperative read for tests and tooling.
public protocol BibleBookmarkRepository: Sendable {
    /// The single write covering every card tap in the bookmark sheet:
    /// - `color` already on `(bookId, chapterNumber)` → remove it (unassign);
    /// - otherwise → assign `color` to the chapter, atomically freeing both
    ///   the colour's previous chapter and the chapter's previous colour, so
    ///   the two 1:1 UNIQUE constraints can never trip mid-flight.
    func toggle(
        color: BibleBookmarkColor,
        bookId: String,
        chapterNumber: Int,
        at now: Date
    ) async throws

    /// Every assigned slot — at most six rows, in a deterministic but
    /// display-agnostic order (see `AllBookmarksRequest`); callers impose
    /// their own ordering.
    func allBookmarks() async throws -> [BibleBookmarkRecord]
}
