import Testing
@testable import Bible

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

@Suite("BibleChapterReader.bottomClearHeight")
@MainActor
struct BibleChapterReaderBottomReserveTests {
    // swift-testing/macOS misreports direct CGFloat equality inside #expect; precompute Bool.
    @Test("the chapter footer clears the floating selection row above the chat pill")
    func noSheetClearsFloatingControls() {
        // Reserve the 60pt chat pill, 36pt inset, 44pt accessory row, and 20pt footer clearance.
        let clearsControls = BibleChapterReader.bottomClearHeight(for: nil) >= 60 + 36 + 44 + 20
        #expect(clearsControls)
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

    @Test("any presented sheet reserves more room than the floating controls")
    func presentedSheetReservesMoreThanBare() {
        let selectionRoomier = BibleChapterReader.bottomClearHeight(for: .selection) > BibleChapterReader.bottomChromeClearance
        let narrationRoomier = BibleChapterReader.bottomClearHeight(for: .narration) > BibleChapterReader.bottomChromeClearance
        #expect(selectionRoomier)
        #expect(narrationRoomier)
    }
}
