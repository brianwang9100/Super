import Testing
@testable import Bible

/// Unit tests for ``BibleChapterReader`` predicates — the bits of the
/// reader's narrate-driven auto-scroll logic and action-sheet appear /
/// dismiss decision that don't need a SwiftUI host. Tests for the actual
/// scroll position live in the screen-level snapshot suite.
@Suite("BibleChapterReader.shouldAutoScroll")
@MainActor
struct BibleChapterReaderTests {
    @Test("auto-scroll runs when the user has not selected any verses")
    func autoScrollWhenNotSuppressed() {
        #expect(BibleChapterReader.shouldAutoScroll(suppressed: false) == true)
    }

    @Test("auto-scroll is suppressed while the user has a selection")
    func autoScrollSuppressedDuringSelection() {
        #expect(BibleChapterReader.shouldAutoScroll(suppressed: true) == false)
    }
}

/// Unit tests for the action-sheet appear predicate that decides when the
/// reader scrolls the selected verse up under the floating sheet. Only the bare
/// appear (`nil → .selection`) scrolls; dismiss no longer scrolls back (the
/// reader stays where it scrolled to), and transitions that don't enter
/// `.selection` from no sheet — including any `.narration` transition, so
/// narration's own follow-scroll stays the sole driver — are `false`. The
/// same-to-same no-op path (`.selection` → `.selection`) is deliberately covered
/// here too. Covered without standing up the reader's SwiftUI host.
@Suite("BibleChapterReader.shouldScrollSelectionIntoView")
@MainActor
struct BibleChapterSheetTransitionTests {
    @Test("opening the action sheet from no sheet scrolls the selection up")
    func scrollsOnAppear() {
        #expect(BibleChapterReader.shouldScrollSelectionIntoView(oldKind: nil, newKind: .selection) == true)
    }

    @Test("closing the action sheet does not scroll back")
    func doesNotScrollOnDismiss() {
        #expect(BibleChapterReader.shouldScrollSelectionIntoView(oldKind: .selection, newKind: nil) == false)
    }

    @Test("narration stepping over the action sheet does not scroll")
    func falseWhenNarrationTakesOver() {
        #expect(BibleChapterReader.shouldScrollSelectionIntoView(oldKind: .selection, newKind: .narration) == false)
    }

    @Test("returning to the action sheet after narration does not scroll")
    func falseWhenSelectionReturnsFromNarration() {
        #expect(BibleChapterReader.shouldScrollSelectionIntoView(oldKind: .narration, newKind: .selection) == false)
    }

    @Test("narration presenting or dismissing without a selection does not scroll")
    func falseForNarrationOnly() {
        #expect(BibleChapterReader.shouldScrollSelectionIntoView(oldKind: nil, newKind: .narration) == false)
        #expect(BibleChapterReader.shouldScrollSelectionIntoView(oldKind: .narration, newKind: nil) == false)
    }

    @Test("a no-op change does not scroll")
    func falseForNoChange() {
        #expect(BibleChapterReader.shouldScrollSelectionIntoView(oldKind: nil, newKind: nil) == false)
        #expect(BibleChapterReader.shouldScrollSelectionIntoView(oldKind: .selection, newKind: .selection) == false)
    }
}
