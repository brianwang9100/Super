import Testing
@testable import Chat

/// Tests for `BibleReferenceLinkifier`'s anchor and continuation
/// matching, skip-region handling, and resilience to false positives.
/// Each suite section maps to a scope bullet in the plan; failures are
/// scoped to one assertion so a regression points straight at the rule
/// that broke.
@Suite("BibleReferenceLinkifier")
struct BibleReferenceLinkifierTests {
    // MARK: - Anchor matching

    @Test func emptyInputReturnsEmpty() {
        #expect(BibleReferenceLinkifier.linkify("") == "")
    }

    @Test func proseWithoutReferencesIsUnchanged() {
        let input = "The user asked about how the system handles streaming responses."
        #expect(BibleReferenceLinkifier.linkify(input) == input)
    }

    @Test func proseWithDigitsButNoBookIsUnchanged() {
        let input = "Section 1:2 of the manual covers it."
        #expect(BibleReferenceLinkifier.linkify(input) == input)
    }

    @Test func proseWithBookNameButNoChapterIsUnchanged() {
        let input = "The Gospel of John mentions it elsewhere."
        #expect(BibleReferenceLinkifier.linkify(input) == input)
    }

    @Test func singleVerseAnchor() {
        let output = BibleReferenceLinkifier.linkify("See Genesis 1:1 for context.")
        #expect(output == "See [Genesis 1:1](super://bible/verse?book=GEN&chapter=1&verses=1) for context.")
    }

    @Test func verseRangeAnchor() {
        let output = BibleReferenceLinkifier.linkify("Romans 8:28-30 is foundational.")
        #expect(output == "[Romans 8:28-30](super://bible/verse?book=ROM&chapter=8&verses=28-30) is foundational.")
    }

    @Test func chapterOnlyAnchor() {
        let output = BibleReferenceLinkifier.linkify("Try Psalm 23 tonight.")
        #expect(output == "Try [Psalm 23](super://bible/verse?book=PSA&chapter=23) tonight.")
    }

    @Test func multiWordBookOneCorinthians() {
        let output = BibleReferenceLinkifier.linkify("1 Corinthians 13:4-7 is the love chapter.")
        #expect(output == "[1 Corinthians 13:4-7](super://bible/verse?book=1CO&chapter=13&verses=4-7) is the love chapter.")
    }

    @Test func multiWordBookSecondJohn() {
        let output = BibleReferenceLinkifier.linkify("2 John 1:3 closes the greeting.")
        #expect(output == "[2 John 1:3](super://bible/verse?book=2JN&chapter=1&verses=3) closes the greeting.")
    }

    @Test func multiWordBookSongOfSolomon() {
        let output = BibleReferenceLinkifier.linkify("Song of Solomon 2:1 is famous.")
        #expect(output == "[Song of Solomon 2:1](super://bible/verse?book=SNG&chapter=2&verses=1) is famous.")
    }

    @Test func psalmAliasResolvesToPsalmsId() {
        let output = BibleReferenceLinkifier.linkify("Psalm 23:1 says the LORD is my shepherd.")
        #expect(output.contains("book=PSA"))
        #expect(output.contains("[Psalm 23:1]"))
    }

    @Test func multipleAnchorsInOneMessage() {
        let output = BibleReferenceLinkifier.linkify("Compare Genesis 1:1 and John 1:1.")
        #expect(output == "Compare [Genesis 1:1](super://bible/verse?book=GEN&chapter=1&verses=1) and [John 1:1](super://bible/verse?book=JHN&chapter=1&verses=1).")
    }

    // MARK: - Continuations

    @Test func continuationAfterSemicolonInheritsBook() {
        let output = BibleReferenceLinkifier.linkify("Romans 8:1; 12:1-2 are foundational.")
        #expect(output == "[Romans 8:1](super://bible/verse?book=ROM&chapter=8&verses=1); [12:1-2](super://bible/verse?book=ROM&chapter=12&verses=1-2) are foundational.")
    }

    @Test func continuationAfterCommaInheritsBook() {
        let output = BibleReferenceLinkifier.linkify("See John 3:16-17, 5:24 for life.")
        #expect(output == "See [John 3:16-17](super://bible/verse?book=JHN&chapter=3&verses=16-17), [5:24](super://bible/verse?book=JHN&chapter=5&verses=24) for life.")
    }

    @Test func freshBookOverridesInheritedContext() {
        let output = BibleReferenceLinkifier.linkify("Romans 8:1, Hebrews 1:1.")
        #expect(output == "[Romans 8:1](super://bible/verse?book=ROM&chapter=8&verses=1), [Hebrews 1:1](super://bible/verse?book=HEB&chapter=1&verses=1).")
    }

    @Test func sentenceBoundaryClearsInheritedBook() {
        // The trailing `12:1-2` has no book context after the period and
        // must stay as plain text.
        let output = BibleReferenceLinkifier.linkify("Romans 8:1. 12:1-2 is in Hebrews.")
        #expect(output.contains("[Romans 8:1]"))
        #expect(!output.contains("[12:1-2]"))
    }

    @Test func continuationRequiresColon() {
        // Bare-chapter continuations are too ambiguous to autolink.
        let output = BibleReferenceLinkifier.linkify("Romans 8:1, 12 follows.")
        #expect(output == "[Romans 8:1](super://bible/verse?book=ROM&chapter=8&verses=1), 12 follows.")
    }

    @Test func paragraphBreakResetsInheritedBook() {
        let input = "Romans 8:1.\n\n12:1-2 is unrelated."
        let output = BibleReferenceLinkifier.linkify(input)
        #expect(!output.contains("[12:1-2]"))
    }

    // MARK: - Skip regions

    @Test func fencedCodeBlockIsNotLinkified() {
        let input = """
        Some prose.

        ```
        Genesis 1:1
        ```

        More prose.
        """
        let output = BibleReferenceLinkifier.linkify(input)
        #expect(output.contains("```\nGenesis 1:1\n```"))
        #expect(!output.contains("[Genesis 1:1]"))
    }

    @Test func inlineCodeIsNotLinkified() {
        let output = BibleReferenceLinkifier.linkify("The token `Genesis 1:1` is literal.")
        #expect(output == "The token `Genesis 1:1` is literal.")
    }

    @Test func existingMarkdownLinkIsNotDoubleLinkified() {
        let input = "See [Romans 8:1](https://example.com/rom) for one view."
        let output = BibleReferenceLinkifier.linkify(input)
        #expect(output == input)
    }

    @Test func referenceStyleMarkdownLinkIsNotDoubleLinkified() {
        // `[text][ref]` is the reference-link shape; the inner `Romans 8:1`
        // must not become a tappable verse — that would produce nested
        // brackets the renderer can't reconcile (CommonMark forbids
        // nested links).
        let input = "See [Romans 8:1][rom] for one view."
        let output = BibleReferenceLinkifier.linkify(input)
        #expect(output == input)
    }

    @Test func collapsedReferenceMarkdownLinkIsNotDoubleLinkified() {
        // `[text][]` — the collapsed-reference shape — has the same
        // nesting hazard as the full reference shape.
        let input = "See [Romans 8:1][] for one view."
        let output = BibleReferenceLinkifier.linkify(input)
        #expect(output == input)
    }

    @Test func shortcutReferenceMarkdownLinkIsNotDoubleLinkified() {
        // `[ref]` on its own (no following `(` or `[`) is the shortcut
        // reference shape; scanning inside it for a verse would emit a
        // tappable link nested in the reference label.
        let input = "See [Romans 8:1] for one view."
        let output = BibleReferenceLinkifier.linkify(input)
        #expect(output == input)
    }

    @Test func prosePastAFencedBlockIsStillLinkified() {
        let input = """
        Intro.

        ```
        not a citation: Genesis 1:1
        ```

        Now the real one: John 3:16.
        """
        let output = BibleReferenceLinkifier.linkify(input)
        #expect(output.contains("```\nnot a citation: Genesis 1:1\n```"))
        #expect(output.contains("[John 3:16]"))
    }

    // MARK: - Rejection / false-positive guards

    @Test func outOfRangeChapterStaysPlain() {
        // Genesis has 50 chapters.
        let output = BibleReferenceLinkifier.linkify("Try Genesis 51:1.")
        #expect(output == "Try Genesis 51:1.")
    }

    @Test func bookFollowedByNonNumericIsIgnored() {
        let output = BibleReferenceLinkifier.linkify("In Genesis the creation account begins.")
        #expect(output == "In Genesis the creation account begins.")
    }

    @Test func bookSeparatedByNewlineIsIgnored() {
        // Citations don't span newlines — keeps `Romans\n8:1` from
        // looking like a real reference when the LLM line-wraps mid-cite.
        let output = BibleReferenceLinkifier.linkify("Romans\n8:1 should not link.")
        #expect(output == "Romans\n8:1 should not link.")
    }

    @Test func bookEmbeddedInLargerWordIsIgnored() {
        // `John` appearing inside `Johnson` must NOT become a link.
        let output = BibleReferenceLinkifier.linkify("Johnson 1:1 is not a book.")
        #expect(output == "Johnson 1:1 is not a book.")
    }

    @Test func lowercaseBookNameIsIgnored() {
        // The system prompt requires canonical capitalization.
        let output = BibleReferenceLinkifier.linkify("see genesis 1:1.")
        #expect(output == "see genesis 1:1.")
    }

    @Test func chapterWithTrailingLettersStaysPlain() {
        let output = BibleReferenceLinkifier.linkify("Genesis 1abc is gibberish.")
        #expect(output == "Genesis 1abc is gibberish.")
    }

    // MARK: - Realistic LLM outputs

    @Test func fullSentenceWithMultipleRefsAndContinuations() {
        let input = "Romans 8:1; 12:1-2 are foundational, see also John 3:16-17, 5:24."
        let output = BibleReferenceLinkifier.linkify(input)
        // Anchors + continuations all linkified, no double-links, no
        // false continuations after the comma between two complete refs.
        #expect(output.contains("[Romans 8:1]"))
        #expect(output.contains("[12:1-2](super://bible/verse?book=ROM&chapter=12&verses=1-2)"))
        #expect(output.contains("[John 3:16-17]"))
        #expect(output.contains("[5:24](super://bible/verse?book=JHN&chapter=5&verses=24)"))
    }

    @Test func messageWithBothProseAndCodeRefsOnlyLinkifiesProse() {
        let input = """
        Look at John 3:16.

        ```
        Print exactly: John 3:16
        ```

        Also Romans 8:28.
        """
        let output = BibleReferenceLinkifier.linkify(input)
        // The two prose references become links.
        let linkCount = output.components(separatedBy: "](super://").count - 1
        #expect(linkCount == 2)
        // The code block keeps its content literal.
        #expect(output.contains("```\nPrint exactly: John 3:16\n```"))
    }
}
