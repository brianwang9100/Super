import Testing
@testable import Bible

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
