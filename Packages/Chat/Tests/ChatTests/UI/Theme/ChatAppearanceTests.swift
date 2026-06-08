import SwiftUI
import Testing
@testable import Chat

/// Tests for `ChatAppearance` — pins the current Claude-tuned defaults
/// (17pt body at 1.0×, `.em(0.39)` line-spacing, 16pt paragraph margin)
/// and verifies that spacing scales monotonically with the single
/// `fontScale` knob so a future tweak to the interpolation anchors is
/// caught here rather than only by re-recorded snapshots.
@Suite("ChatAppearance")
struct ChatAppearanceTests {
    @Test("default appearance matches the documented Claude-tuned values")
    func defaultMatchesDocumentedDefaults() {
        let a = ChatAppearance.default
        #expect(a.fontScale == 1.0)
        // Body size: 17pt baseline tuned to match Claude iOS chat at default Dynamic Type.
        #expect(a.bodyFontSize == 17)
        // Paragraph intra-line spacing at 1.0× anchor.
        #expect(a.paragraphLineSpacingEm == 0.39)
        // Inter-paragraph margin at 1.0× anchor (~one empty line at 17pt body).
        #expect(a.paragraphSpacing == 16)
        // Bubble inner padding at 1.0× anchor.
        #expect(a.bubbleInnerVerticalPadding == 10)
        // Bubble row padding at 1.0× anchor.
        #expect(a.bubbleRowVerticalPadding == 4)
        // Assistant row padding at 1.0× anchor.
        #expect(a.assistantRowVerticalPadding == 2)
    }

    @Test("fontScale extremes resolve to the documented 0.80× / 1.20× body size")
    func fontScaleEndpointsScaleBodySize() {
        #expect(ChatAppearance(fontScale: 0.80).bodyFontSize == 17 * 0.80)
        #expect(ChatAppearance(fontScale: 1.20).bodyFontSize == 17 * 1.20)
    }

    @Test("fontScale anchors map to compact / comfortable / spacious line-spacing")
    func anchorsMatchLineSpacingPresets() {
        #expect(ChatAppearance(fontScale: 0.80).paragraphLineSpacingEm == 0.30)
        #expect(ChatAppearance(fontScale: 1.00).paragraphLineSpacingEm == 0.39)
        #expect(ChatAppearance(fontScale: 1.20).paragraphLineSpacingEm == 0.54)
    }

    @Test("fontScale anchors map to compact / comfortable / spacious paragraph margin")
    func anchorsMatchParagraphSpacingPresets() {
        #expect(ChatAppearance(fontScale: 0.80).paragraphSpacing == 10)
        #expect(ChatAppearance(fontScale: 1.00).paragraphSpacing == 16)
        #expect(ChatAppearance(fontScale: 1.20).paragraphSpacing == 25)
    }

    @Test("line-spacing-in-points equals the em line spacing resolved against body size")
    func lineSpacingPointsResolvesEmAgainstBody() {
        // The point value the list-item margin uses is the em line spacing
        // resolved against the body size, so the gap between list items tracks
        // the wrapped-line gap inside an item. (MarkdownUI rounds the gap it
        // actually paints, so the two differ by a sub-point — below visual
        // threshold; see paragraphLineSpacingPoints' doc.)
        for scale in [0.80, 0.90, 1.00, 1.10, 1.20] {
            let a = ChatAppearance(fontScale: scale)
            #expect(a.paragraphLineSpacingPoints == a.paragraphLineSpacingEm * a.bodyFontSize)
        }
        // Anchor points: 0.30×13.6 / 0.39×17 / 0.54×20.4.
        #expect(abs(ChatAppearance(fontScale: 0.80).paragraphLineSpacingPoints - 4.08) < 0.0001)
        #expect(abs(ChatAppearance(fontScale: 1.00).paragraphLineSpacingPoints - 6.63) < 0.0001)
        #expect(abs(ChatAppearance(fontScale: 1.20).paragraphLineSpacingPoints - 11.016) < 0.0001)
    }

    @Test("line-spacing-in-points grows monotonically with the font slider")
    func lineSpacingPointsIsMonotonic() {
        let small = ChatAppearance(fontScale: 0.80).paragraphLineSpacingPoints
        let mid = ChatAppearance(fontScale: 1.00).paragraphLineSpacingPoints
        let large = ChatAppearance(fontScale: 1.20).paragraphLineSpacingPoints
        #expect(small < mid)
        #expect(mid < large)
    }

    @Test("paragraph line-spacing grows monotonically with the font slider")
    func lineSpacingIsMonotonic() {
        let small = ChatAppearance(fontScale: 0.80).paragraphLineSpacingEm
        let mid = ChatAppearance(fontScale: 1.00).paragraphLineSpacingEm
        let large = ChatAppearance(fontScale: 1.20).paragraphLineSpacingEm
        #expect(small < mid)
        #expect(mid < large)
    }

    @Test("paragraph margin grows monotonically with the font slider")
    func paragraphSpacingIsMonotonic() {
        let small = ChatAppearance(fontScale: 0.80).paragraphSpacing
        let mid = ChatAppearance(fontScale: 1.00).paragraphSpacing
        let large = ChatAppearance(fontScale: 1.20).paragraphSpacing
        #expect(small < mid)
        #expect(mid < large)
    }

    @Test("bubble paddings grow monotonically with the font slider")
    func rowPaddingsAreMonotonic() {
        let small = ChatAppearance(fontScale: 0.80)
        let mid = ChatAppearance(fontScale: 1.00)
        let large = ChatAppearance(fontScale: 1.20)
        #expect(small.bubbleRowVerticalPadding < mid.bubbleRowVerticalPadding)
        #expect(mid.bubbleRowVerticalPadding < large.bubbleRowVerticalPadding)
        #expect(small.bubbleInnerVerticalPadding < mid.bubbleInnerVerticalPadding)
        #expect(mid.bubbleInnerVerticalPadding < large.bubbleInnerVerticalPadding)
        #expect(small.assistantRowVerticalPadding < mid.assistantRowVerticalPadding)
        #expect(mid.assistantRowVerticalPadding < large.assistantRowVerticalPadding)
    }

    @Test("intermediate slider value interpolates linearly between anchors")
    func intermediateScaleInterpolates() {
        // Halfway between 0.80 and 1.00 should be halfway between the
        // low and mid anchors on every derived axis.
        let halfwayLow = ChatAppearance(fontScale: 0.90)
        #expect(abs(halfwayLow.paragraphLineSpacingEm - 0.345) < 0.0001)
        #expect(abs(halfwayLow.paragraphSpacing - 13) < 0.0001)
        // Halfway between 1.00 and 1.20 mirrors on the upper segment.
        let halfwayHigh = ChatAppearance(fontScale: 1.10)
        #expect(abs(halfwayHigh.paragraphLineSpacingEm - 0.465) < 0.0001)
        #expect(abs(halfwayHigh.paragraphSpacing - 20.5) < 0.0001)
    }

    @Test("init clamps fontScale to the documented [0.80, 1.20] range")
    func initClamps() {
        #expect(ChatAppearance(fontScale: 0.5).fontScale == 0.80)
        #expect(ChatAppearance(fontScale: 2.0).fontScale == 1.20)
    }

    @Test("Equatable conformance honors fontScale")
    func equality() {
        let a = ChatAppearance(fontScale: 1.0)
        let b = ChatAppearance(fontScale: 1.0)
        let differentScale = ChatAppearance(fontScale: 1.05)
        #expect(a == b)
        #expect(a != differentScale)
    }
}
