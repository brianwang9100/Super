import SwiftUI
import Testing
@testable import Bible

@Suite("Shared Bible verse decoration style")
struct BibleVerseDecorationStyleTests {
    @Test("Solid selection takes precedence over softer dashed narration")
    func selectionPrecedence() {
        let selection = BibleVerseDecorationStyle(bodySize: 24, isSelected: true, isNarrating: true)
        #expect(selection.underline == .selection)
        #expect(selection.underlineOpacity == 1)
        #expect(selection.strokeStyle.dash.isEmpty)
        let narration = BibleVerseDecorationStyle(bodySize: 24, isSelected: false, isNarrating: true)
        #expect(narration.underline == .narration)
        #expect(narration.underlineOpacity == 0.65)
        #expect(narration.strokeStyle.dash == [3, 3])
        #expect(BibleVerseDecorationStyle(bodySize: 24, isSelected: false, isNarrating: false).underline == .none)
    }

    @Test("Baseline placement and line weight retain existing reader metrics across font scales")
    func fontScaleMetrics() {
        let normal = BibleVerseDecorationStyle(bodySize: 19, isSelected: true, isNarrating: false)
        #expect(abs(normal.baselineDrop - 4.18) < 0.0001)
        #expect(abs(normal.highlightBandHeight - 23.18) < 0.0001)
        #expect(normal.underlineWeight == 2)
        #expect(BibleVerseDecorationStyle(bodySize: 48, isSelected: true, isNarrating: false).underlineWeight == 5)
        #expect(BibleVerseDecorationStyle(bodySize: 5, isSelected: true, isNarrating: false).underlineWeight == 1)
    }
}
