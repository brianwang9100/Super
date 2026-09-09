import Foundation

public protocol BibleBookmarkRepository: Sendable {
    /// Removes a color already on this chapter. Otherwise atomically frees both the
    /// color's previous chapter and the chapter's previous color before assigning.
    func toggle(
        color: BibleBookmarkColor,
        bookId: String,
        chapterNumber: Int,
        at now: Date
    ) async throws

    /// At most six rows in deterministic storage order; callers impose display order.
    func allBookmarks() async throws -> [BibleBookmarkRecord]
}
