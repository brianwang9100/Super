import Testing
@testable import Bible

/// Tests for `BibleVerseAnnouncement` — the VoiceOver label that lets a
/// verse's first word stand in for the whole verse, and the value naming its
/// highlight.
@Suite("BibleVerseAnnouncement")
struct BibleVerseAnnouncementTests {
    @Test("a prose verse reads as its number then its text")
    func proseLabel() {
        #expect(
            BibleVerseAnnouncement.label(verseNumber: 9, verseText: "But you are a chosen race")
                == "Verse 9. But you are a chosen race"
        )
    }

    @Test("poetry line breaks collapse so the verse reads as continuous prose")
    func poetryLineBreaksCollapse() {
        #expect(
            BibleVerseAnnouncement.label(verseNumber: 1, verseText: "Praise the LORD!\nSing to him")
                == "Verse 1. Praise the LORD! Sing to him"
        )
    }

    @Test("runs of whitespace collapse to single spaces")
    func whitespaceRunsCollapse() {
        #expect(
            BibleVerseAnnouncement.label(verseNumber: 3, verseText: "  spaced \n\n  out  ")
                == "Verse 3. spaced out"
        )
    }

    @Test(
        "a highlighted verse announces its colour as the value",
        arguments: [
            (BibleHighlightColor.yellow, "Highlighted yellow"),
            (.green, "Highlighted green"),
            (.blue, "Highlighted blue"),
            (.pink, "Highlighted pink"),
            (.lavender, "Highlighted lavender"),
        ]
    )
    func highlightValueNamesTheColour(color: BibleHighlightColor, expected: String) {
        #expect(BibleVerseAnnouncement.highlightValue(color) == expected)
    }

    @Test("an unhighlighted verse has an empty value")
    func emptyValueWhenNotHighlighted() {
        #expect(BibleVerseAnnouncement.highlightValue(nil) == "")
    }
}
