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

/// Unit tests for the action-sheet appear / dismiss predicate that decides
/// when the reader runs its paired selection scroll. Only entering or leaving
/// `.selection` scrolls; transitions that don't touch `.selection` (so
/// narration's own follow-scroll stays the sole driver) return `nil`. The
/// same-to-same no-op path (`.selection` → `.selection`) is deliberately
/// covered here too. Covered without standing up the reader's SwiftUI host.
@Suite("BibleChapterReader.selectionSheetTransition")
@MainActor
struct BibleChapterSheetTransitionTests {
    @Test("opening the action sheet from no sheet is appearing")
    func appearingFromNil() {
        #expect(BibleChapterReader.selectionSheetTransition(oldKind: nil, newKind: .selection) == .appearing)
    }

    @Test("closing the action sheet to no sheet is dismissing")
    func dismissingToNil() {
        #expect(BibleChapterReader.selectionSheetTransition(oldKind: .selection, newKind: nil) == .dismissing)
    }

    @Test("narration stepping over the action sheet does not scroll")
    func nilWhenNarrationTakesOver() {
        #expect(BibleChapterReader.selectionSheetTransition(oldKind: .selection, newKind: .narration) == nil)
    }

    @Test("returning to the action sheet after narration does not scroll")
    func nilWhenSelectionReturnsFromNarration() {
        #expect(BibleChapterReader.selectionSheetTransition(oldKind: .narration, newKind: .selection) == nil)
    }

    @Test("narration presenting or dismissing without a selection does not scroll")
    func nilForNarrationOnly() {
        #expect(BibleChapterReader.selectionSheetTransition(oldKind: nil, newKind: .narration) == nil)
        #expect(BibleChapterReader.selectionSheetTransition(oldKind: .narration, newKind: nil) == nil)
    }

    @Test("a no-op change does not scroll")
    func nilForNoChange() {
        #expect(BibleChapterReader.selectionSheetTransition(oldKind: nil, newKind: nil) == nil)
        #expect(BibleChapterReader.selectionSheetTransition(oldKind: .selection, newKind: .selection) == nil)
    }
}
