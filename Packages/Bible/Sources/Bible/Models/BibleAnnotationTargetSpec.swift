import Foundation

/// A fully-specified annotation target: which book, which chapter (when
/// relevant), which verse range (when relevant).
///
/// Pairs the polymorphic `BibleAnnotationTarget` discriminator with the
/// IDs needed to address one specific row group. Used by the annotation
/// sheet (as its identity for `.sheet(item:)`), by the chapter reader
/// when grouping rows for trailing bubbles, by the book picker when a
/// bubble is tapped, and by `BibleScreenViewModel` when it queues a
/// generation intent behind the first-run disclaimer.
///
/// The `book` form addresses every annotation on a book regardless of
/// chapter; `chapter` addresses chapter-level annotations only (rows with
/// `verseEnd == nil`); `verseRange` addresses one contiguous selection.
public enum BibleAnnotationTargetSpec: Sendable, Equatable, Hashable, Identifiable {
    case book(bookId: String)
    case chapter(bookId: String, chapterNumber: Int)
    case verseRange(bookId: String, chapterNumber: Int, verseStart: Int, verseEnd: Int)

    /// Stable string identity for `.sheet(item:)` and `ForEach` diffing.
    /// Encodes the case discriminator plus its associated values so two
    /// adjacent verse ranges in the same chapter don't collapse.
    public var id: String {
        switch self {
        case .book(let bookId):
            return "book:\(bookId)"
        case .chapter(let bookId, let chapterNumber):
            return "chapter:\(bookId):\(chapterNumber)"
        case .verseRange(let bookId, let chapterNumber, let verseStart, let verseEnd):
            return "verse:\(bookId):\(chapterNumber):\(verseStart):\(verseEnd)"
        }
    }

    /// The corresponding polymorphic-table discriminator.
    public var target: BibleAnnotationTarget {
        switch self {
        case .book: return .book
        case .chapter: return .chapter
        case .verseRange: return .verse
        }
    }

    public var bookId: String {
        switch self {
        case .book(let bookId),
             .chapter(let bookId, _),
             .verseRange(let bookId, _, _, _):
            return bookId
        }
    }

    public var chapterNumber: Int? {
        switch self {
        case .book: return nil
        case .chapter(_, let n), .verseRange(_, let n, _, _): return n
        }
    }

    public var verseStart: Int? {
        if case .verseRange(_, _, let start, _) = self { return start }
        return nil
    }

    public var verseEnd: Int? {
        if case .verseRange(_, _, _, let end) = self { return end }
        return nil
    }
}
