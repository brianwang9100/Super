import Foundation
import Observation

/// One selector presentation's draft passage and translation, isolated from the reader until Read.
@MainActor
@Observable
public final class BibleSelectionSheetViewModel: Identifiable {
    enum Tab: String, CaseIterable {
        case book = "Book & chapter"
        case translation = "Translation"
    }

    /// Stable identity for the lifetime of the native selector sheet.
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    let bookPicker: BibleBookSheetViewModel
    var tab: Tab = .book
    private(set) var position: BiblePosition
    var translation: BibleTranslation
    private(set) var verseRange: ClosedRange<Int>?
    private let catalog: BibleBookCatalog

    init(position: BiblePosition, translation: BibleTranslation, catalog: BibleBookCatalog = .standard) {
        self.position = position
        self.translation = translation
        self.catalog = catalog
        self.bookPicker = BibleBookSheetViewModel(currentPosition: position, catalog: catalog)
    }

    var citation: String {
        let name = catalog.book(id: position.bookId)?.name ?? position.bookId
        let chapter = "\(name) \(position.chapterNumber)"
        guard let verseRange else { return chapter }
        let verses = verseRange.lowerBound == verseRange.upperBound
            ? "\(verseRange.lowerBound)" : "\(verseRange.lowerBound)-\(verseRange.upperBound)"
        return "\(chapter):\(verses)"
    }

    func selectChapter(bookId: String, chapterNumber: Int) {
        guard isValid(bookId: bookId, chapterNumber: chapterNumber) else { return }
        position = BiblePosition(bookId: bookId, chapterNumber: chapterNumber)
        verseRange = nil
    }

    func selectVerseRange(bookId: String, chapterNumber: Int, verseStart: Int, verseEnd: Int) {
        guard isValid(bookId: bookId, chapterNumber: chapterNumber),
              verseStart > 0, verseEnd >= verseStart else { return }
        position = BiblePosition(bookId: bookId, chapterNumber: chapterNumber)
        // Keep only bounds. Application intersects them with loaded verses, even for Int.max.
        verseRange = verseStart...verseEnd
    }

    private func isValid(bookId: String, chapterNumber: Int) -> Bool {
        guard let book = catalog.book(id: bookId) else { return false }
        return (1...book.chapterCount).contains(chapterNumber)
    }
}
