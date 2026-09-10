import Foundation

/// Identifies one exact target group: book-level, chapter-level, or a contiguous verse range.
public enum BibleAnnotationTargetSpec: Sendable, Equatable, Hashable, Identifiable {
    case book(bookId: String)
    case chapter(bookId: String, chapterNumber: Int)
    case verseRange(bookId: String, chapterNumber: Int, verseStart: Int, verseEnd: Int)

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
