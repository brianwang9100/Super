import Testing
@testable import Bible

/// Tests for the bookmark surfaces' factored VoiceOver label builders — the
/// chapter-title glyph (`BibleChapterReader.chapterBookmarkLabel`), the sheet's
/// slot cards (`BookmarkSlotButton.label`), and the book picker's row cluster +
/// chapter-cell labels (`BibleBookSheet.bookBookmarksLabel` /
/// `chapterCellLabel`). `@MainActor` because the statics live on `View` types,
/// whose members are MainActor-isolated.
@Suite("Bookmark accessibility labels")
@MainActor
struct BookmarkAccessibilityTests {
    @Test("the chapter glyph offers to bookmark when the chapter has no ribbon")
    func chapterGlyphEmptyLabel() {
        #expect(BibleChapterReader.chapterBookmarkLabel(for: nil) == "Bookmark this chapter")
    }

    @Test("the chapter glyph names the ribbon when the chapter is bookmarked")
    func chapterGlyphFilledLabel() {
        #expect(
            BibleChapterReader.chapterBookmarkLabel(for: .clay)
                == "Chapter bookmarked Clay — edit bookmark"
        )
    }

    @Test("an empty slot card offers to assign here")
    func slotEmptyLabel() {
        let label = BookmarkSlotButton.label(
            color: .gold, assignedCitation: nil, isCurrentChapter: false, currentCitation: "John 3"
        )
        #expect(label == "Gold bookmark, empty. Assign to John 3")
    }

    @Test("a slot assigned elsewhere offers to move here")
    func slotMoveLabel() {
        let label = BookmarkSlotButton.label(
            color: .gold, assignedCitation: "Romans 8", isCurrentChapter: false, currentCitation: "John 3"
        )
        #expect(label == "Gold bookmark on Romans 8. Move to John 3")
    }

    @Test("the current chapter's own slot offers to remove")
    func slotRemoveLabel() {
        let label = BookmarkSlotButton.label(
            color: .gold, assignedCitation: "John 3", isCurrentChapter: true, currentCitation: "John 3"
        )
        #expect(label == "Gold bookmark on John 3. Remove bookmark")
    }

    @Test("a book row's bookmark cluster reads as one combined element")
    func bookRowClusterLabel() {
        let label = BibleBookSheet.bookBookmarksLabel([
            (color: .clay, chapterNumber: 3),
            (color: .gold, chapterNumber: 8),
        ])
        #expect(label == "Bookmarks: Clay chapter 3, Gold chapter 8")
    }

    @Test("a chapter cell without a bookmark keeps its plain label")
    func chapterCellPlainLabel() {
        #expect(
            BibleBookSheet.chapterCellLabel(bookName: "Genesis", number: 1, bookmark: nil)
                == "Genesis chapter 1"
        )
    }

    @Test("a bookmarked chapter cell appends its ribbon colour")
    func chapterCellBookmarkedLabel() {
        #expect(
            BibleBookSheet.chapterCellLabel(bookName: "Genesis", number: 3, bookmark: .clay)
                == "Genesis chapter 3, bookmarked Clay"
        )
    }
}
