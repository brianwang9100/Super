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

/// Unit tests for the action-sheet appear / dismiss predicate that
/// decides when the reader should run a paired scroll. The three branches
/// — `.appearing`, `.dismissing`, and "no scroll" — are covered without
/// standing up the reader's SwiftUI host.
@Suite("BibleChapterReader.sheetTransition")
@MainActor
struct BibleChapterSheetTransitionTests {
    @Test("inset growing from zero is classified as appearing")
    func appearingOnInsetGrowFromZero() {
        #expect(BibleChapterReader.sheetTransition(oldInset: 0, newInset: 224) == .appearing)
    }

    @Test("inset shrinking to zero is classified as dismissing")
    func dismissingOnInsetShrinkToZero() {
        #expect(BibleChapterReader.sheetTransition(oldInset: 224, newInset: 0) == .dismissing)
    }

    @Test("mid-show remeasurement between two non-zero values does not scroll")
    func nilOnNonZeroRemeasurement() {
        #expect(BibleChapterReader.sheetTransition(oldInset: 24, newInset: 224) == nil)
    }

    @Test("a zero-to-zero spurious change does not scroll")
    func nilOnZeroToZero() {
        #expect(BibleChapterReader.sheetTransition(oldInset: 0, newInset: 0) == nil)
    }
}
