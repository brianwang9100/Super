import Testing
@testable import Bible

/// Tests for the bookmark surfaces' factored VoiceOver label builders — the
/// chapter-title glyph (`BibleChapterReader.chapterBookmarkLabel`) and the
/// sheet's slot cards (`BookmarkSlotButton.label`). `@MainActor` because the
/// statics live on `View` types, whose members are MainActor-isolated.
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
}
