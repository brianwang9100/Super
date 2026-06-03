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

/// Unit tests for the reader's bottom scroll reserve. With no sheet up the
/// reader reserves only the chat-pill clearance; while the floating action or
/// narration sheet is presented it reserves that sheet's height plus a margin,
/// so the last verses + footer can scroll clear of the sheet instead of staying
/// stuck behind it. Regression guard for the inset dropped in the native-sheet
/// migration (#152). Covered without standing up the reader's SwiftUI host.
@Suite("BibleChapterReader.bottomClearHeight")
@MainActor
struct BibleChapterReaderBottomReserveTests {
    // CGFloat `==` evaluated directly inside `#expect` mis-reports on
    // swift-testing/macOS (the documented in-tree quirk), so each equality is
    // precomputed into a `Bool` and that is expected instead.
    @Test("no sheet reserves only the chat-pill clearance")
    func noSheetReservesChatPillOnly() {
        let matches = BibleChapterReader.bottomClearHeight(for: nil) == BibleChapterReader.chatPillHeight
        #expect(matches)
    }

    @Test("the action sheet reserves its height plus the overlay margin")
    func selectionReservesSheetPlusMargin() {
        let expected = BibleBottomOverlayKind.selection.estimatedSheetHeight
            + BibleChapterReader.overlayBottomReserve
        let matches = BibleChapterReader.bottomClearHeight(for: .selection) == expected
        #expect(matches)
    }

    @Test("the narration card reserves its height plus the overlay margin")
    func narrationReservesSheetPlusMargin() {
        let expected = BibleBottomOverlayKind.narration.estimatedSheetHeight
            + BibleChapterReader.overlayBottomReserve
        let matches = BibleChapterReader.bottomClearHeight(for: .narration) == expected
        #expect(matches)
    }

    @Test("any presented sheet reserves more room than the bare chat pill")
    func presentedSheetReservesMoreThanBare() {
        let selectionRoomier = BibleChapterReader.bottomClearHeight(for: .selection) > BibleChapterReader.chatPillHeight
        let narrationRoomier = BibleChapterReader.bottomClearHeight(for: .narration) > BibleChapterReader.chatPillHeight
        #expect(selectionRoomier)
        #expect(narrationRoomier)
    }
}
