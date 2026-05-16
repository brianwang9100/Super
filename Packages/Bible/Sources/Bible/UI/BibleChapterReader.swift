import Core
import GRDBQuery
import SwiftUI

/// The scrolling chapter column: the chapter title, its heading / prose /
/// poetry paragraphs, and the prev / next footer.
///
/// Verse highlights are bound reactively here through GRDBQuery's `@Query`,
/// which observes the chapter's `bibleHighlight` rows: a highlight written
/// from the action sheet — or, later, restored by sync — repaints the verse
/// without this view reloading. `BibleScreen` gives the reader a fresh
/// identity per chapter, so the constant `@Query` request always carries the
/// on-screen position.
struct BibleChapterReader: View {
    @Environment(\.superTheme) private var theme
    @Query<ChapterHighlightsRequest> private var highlights: [BibleHighlightRecord]

    private let chapter: BibleChapter
    private let bookName: String
    private let selectedVerses: Set<Int>
    private let previousLabel: String?
    private let nextLabel: String?
    private let onTapVerse: (Int) -> Void
    private let onPrevious: () -> Void
    private let onNext: () -> Void
    private let onClearSelection: () -> Void

    /// - Parameters:
    ///   - bookId: the book whose highlights the `@Query` observes; paired
    ///     with `chapter.number` it scopes the observation to this chapter.
    ///   - onClearSelection: invoked when a tap lands on the column but misses
    ///     every verse word.
    init(
        chapter: BibleChapter,
        bookId: String,
        bookName: String,
        selectedVerses: Set<Int>,
        previousLabel: String?,
        nextLabel: String?,
        onTapVerse: @escaping (Int) -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onClearSelection: @escaping () -> Void
    ) {
        _highlights = Query(constant: ChapterHighlightsRequest(
            bookId: bookId,
            chapterNumber: chapter.number
        ))
        self.chapter = chapter
        self.bookName = bookName
        self.selectedVerses = selectedVerses
        self.previousLabel = previousLabel
        self.nextLabel = nextLabel
        self.onTapVerse = onTapVerse
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onClearSelection = onClearSelection
    }

    /// Highlight colour keyed by verse number, decoded from the observed rows.
    private var highlightsByVerse: [Int: BibleHighlightColor] {
        var map: [Int: BibleHighlightColor] = [:]
        for record in highlights {
            guard let color = record.color else { continue }
            map[record.verseNumber] = color
        }
        return map
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(bookName) \(chapter.number)")
                    .font(.system(.largeTitle, design: .serif))
                    .italic()
                    .foregroundStyle(theme.ink)
                    .padding(.bottom, 6)

                let highlightsByVerse = highlightsByVerse
                ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    BibleParagraphBlock(
                        paragraph: paragraph,
                        selectedVerses: selectedVerses,
                        highlightedVerses: highlightsByVerse,
                        onTapVerse: onTapVerse
                    )
                }

                BibleChapterFooter(
                    previousLabel: previousLabel,
                    nextLabel: nextLabel,
                    onPrevious: onPrevious,
                    onNext: onNext
                )

                // Bottom inset so the chat overlay's minimized pill doesn't
                // obscure the footer — mirrors the shell's 76pt reserve.
                Color.clear.frame(height: 76)
            }
            .padding(.horizontal, 26)
            // Top inset clears the floating nav bar; the bar's gradient
            // fades over the first lines as they scroll up beneath it.
            .padding(.top, 68)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A tap that misses every verse word clears the selection.
            .contentShape(Rectangle())
            .onTapGesture { onClearSelection() }
        }
    }
}
