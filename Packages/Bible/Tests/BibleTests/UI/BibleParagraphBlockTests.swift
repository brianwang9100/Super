import Testing
@testable import Bible

/// Unit tests for `BibleParagraphBlock` static helpers — the bits that
/// don't need a SwiftUI host. Visual placement of words + trailing
/// annotation bubbles lives in the chapter-reader snapshot suite.
@Suite("BibleParagraphBlock.trailingBubbleLabel")
@MainActor
struct BibleParagraphBlockTrailingBubbleLabelTests {
    @Test("a single-verse range labels the verse number")
    func singleVerse() {
        let spec = BibleAnnotationTargetSpec.verseRange(
            bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 28
        )
        #expect(BibleParagraphBlock.trailingBubbleLabel(for: spec) == "View annotation for verse 28")
    }

    @Test("a multi-verse range labels the inclusive bounds")
    func multiVerse() {
        let spec = BibleAnnotationTargetSpec.verseRange(
            bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
        )
        #expect(BibleParagraphBlock.trailingBubbleLabel(for: spec) == "View annotation for verses 28–30")
    }

    @Test("a chapter spec falls back to a non-verse label")
    func chapterFallback() {
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        #expect(BibleParagraphBlock.trailingBubbleLabel(for: spec) == "View chapter annotation")
    }

    @Test("a book spec falls back to a non-verse label")
    func bookFallback() {
        let spec = BibleAnnotationTargetSpec.book(bookId: "ROM")
        #expect(BibleParagraphBlock.trailingBubbleLabel(for: spec) == "View book annotation")
    }
}
