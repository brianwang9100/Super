import Testing
@testable import Bible

/// Guards the saved-highlight cross-fade lost in #252.
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
