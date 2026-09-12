import CoreGraphics
import Testing
@testable import Bible

@Suite("Bible reading layout")
struct BibleReadingLayoutTests {
    @Test(arguments: [CGFloat(375), 744, 834, 1024, 1376])
    func capableReaderUsesAssignedWidth(width: CGFloat) {
        let layout = BibleReadingLayout(isPadWorkspace: true)
        #expect(layout.contentWidth(availableWidth: width) == max(0, width - 52))
        #expect(layout.bodySize == 24)
    }

    @Test func phoneKeepsExistingTypography() {
        #expect(BibleReadingLayout.legacy.bodySize == 19)
        #expect(BibleReadingLayout.legacy.contentWidth(availableWidth: 1024) == 708)
    }

    @Test func measuredControlsUseActualOcclusion() {
        #expect(BibleReadingLayout.bottomClearance(measuredBarHeight: 127, safeAreaReserved: false) == 127)
        #expect(BibleReadingLayout.bottomClearance(measuredBarHeight: 127, safeAreaReserved: true) == 0)
        #expect(BibleReadingLayout.bottomClearance(measuredBarHeight: -1, safeAreaReserved: false) == 0)
    }

    @Test func dockedControlsDoNotUseSheetEstimates() {
        let layout = BibleChapterReaderLayout(topInset: 68, bottomInset: 16, usesSafeAreaStudyBar: true)
        #expect(BibleChapterReader.bottomClearHeight(for: .selection, layout: layout) == 16)
        #expect(BibleChapterReader.bottomClearHeight(for: .narration, layout: layout) == 16)
    }

    @Test func appScaleComposesOnce() {
        let layout = BibleReadingLayout(isPadWorkspace: true)
        #expect(abs(layout.bodySize * 1.2 - 28.8) < 0.0001)
    }
}
