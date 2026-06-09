import Testing
@testable import Bible

/// Tests for `BibleHighlightWashMotion` — that the Reduce Motion setting maps
/// the saved-highlight wash to an instant repaint (`nil` animation) and its
/// absence to the cross-fade curve. Regression coverage for the wash fade that
/// PR #252 silently dropped.
@Suite("BibleHighlightWashMotion")
struct BibleHighlightWashMotionTests {
    @Test("Reduce Motion off resolves to the full cross-fade")
    func reduceMotionOffIsFull() {
        #expect(BibleHighlightWashMotion(reduceMotion: false) == .full)
    }

    @Test("Reduce Motion on resolves to the reduced (instant) variant")
    func reduceMotionOnIsReduced() {
        #expect(BibleHighlightWashMotion(reduceMotion: true) == .reduced)
    }

    @Test("the full variant carries a non-nil animation so the wash fades")
    func fullHasAnimation() {
        #expect(BibleHighlightWashMotion.full.animation != nil)
    }

    @Test("the reduced variant carries no animation so the wash repaints instantly")
    func reducedHasNoAnimation() {
        #expect(BibleHighlightWashMotion.reduced.animation == nil)
    }
}
