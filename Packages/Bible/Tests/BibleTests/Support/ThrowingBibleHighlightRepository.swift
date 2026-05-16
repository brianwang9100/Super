import Foundation
@testable import Bible

/// A `BibleHighlightRepository` whose every write throws — exercises the
/// view model's highlight-failure toast path.
struct ThrowingBibleHighlightRepository: BibleHighlightRepository {
    struct WriteFailure: Error {}

    func setHighlight(
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        color: BibleHighlightColor,
        at now: Date
    ) async throws {
        throw WriteFailure()
    }

    func clearHighlight(
        bookId: String,
        chapterNumber: Int,
        verseNumber: Int,
        at now: Date
    ) async throws {
        throw WriteFailure()
    }
}
