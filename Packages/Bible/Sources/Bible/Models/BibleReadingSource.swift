import Foundation

public struct BibleReadingSource: Sendable, Equatable {
    public let position: BiblePosition
    public let translation: BibleTranslation
    public let chapter: BibleChapter

    public init(position: BiblePosition, translation: BibleTranslation, chapter: BibleChapter) {
        self.position = position
        self.translation = translation
        self.chapter = chapter
    }
}

public enum BibleReadingSourceError: Error, Sendable {
    case unavailable
}
