import Testing
@testable import Bible

/// Tests for `BibleVerseTextFormatter` — the numbered plain-text rendering of a
/// verse list shared by the `bible.read` tool and annotation grounding.
@Suite("BibleVerseTextFormatter")
struct BibleVerseTextFormatterTests {
    @Test("a single verse renders as one numbered line")
    func singleVerse() {
        let out = BibleVerseTextFormatter.numbered([
            BibleVerse(number: 16, text: "For God so loved the world."),
        ])
        #expect(out == "16. For God so loved the world.")
    }

    @Test("a range renders one numbered line per verse, newline-joined")
    func range() {
        let out = BibleVerseTextFormatter.numbered([
            BibleVerse(number: 16, text: "A."),
            BibleVerse(number: 17, text: "B."),
        ])
        #expect(out == "16. A.\n17. B.")
    }

    @Test("verse numbers are emitted in the order given, not re-sorted")
    func preservesOrder() {
        let out = BibleVerseTextFormatter.numbered([
            BibleVerse(number: 2, text: "Second."),
            BibleVerse(number: 1, text: "First."),
        ])
        #expect(out == "2. Second.\n1. First.")
    }

    @Test("an empty input yields the empty string")
    func empty() {
        #expect(BibleVerseTextFormatter.numbered([]) == "")
    }
}
