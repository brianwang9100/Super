import Testing
@testable import Bible

/// Tests for `BibleSheetMotion` — that the Reduce Motion setting maps to the
/// cross-fade presentation and its absence to the default slide.
@Suite("BibleSheetMotion")
struct BibleSheetMotionTests {
    @Test("Reduce Motion off resolves to the full slide presentation")
    func reduceMotionOffIsFull() {
        #expect(BibleSheetMotion(reduceMotion: false) == .full)
    }

    @Test("Reduce Motion on resolves to the reduced cross-fade presentation")
    func reduceMotionOnIsReduced() {
        #expect(BibleSheetMotion(reduceMotion: true) == .reduced)
    }
}
