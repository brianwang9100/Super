import Core
import SwiftUI
import Testing
@testable import Chat

/// Tests for `ChatAppearance` — pins the current Claude-tuned defaults
/// (19pt reading body at 1.0×, constant `SuperTypography.readingLeadingEm`
/// line-spacing shared with the Bible reader, ≈17.9pt paragraph margin) and
/// verifies that spacing scales monotonically with the single `fontScale` knob
/// so a future tweak to the interpolation anchors is caught here rather than
/// only by re-recorded snapshots.
@Suite("ChatAppearance")
struct ChatAppearanceTests {
    @Test("default appearance matches the documented Claude-tuned values")
    func defaultMatchesDocumentedDefaults() {
        let a = ChatAppearance.default
        #expect(a.fontScale == 1.0)
        // Body size: 19pt reading baseline (SuperTypography.readingBodySize).
        #expect(a.bodyFontSize == 19)
        // Intra-paragraph leading: the shared constant em (≈0.235), same as the Bible reader.
        #expect(a.paragraphLineSpacingEm == SuperTypography.readingLeadingEm)
        // Inter-paragraph margin at 1.0× anchor (≈one empty line at 19pt body).
        #expect(abs(a.paragraphSpacing - 17.8824) < 0.0001)
        // Bubble inner padding at 1.0× anchor.
        #expect(a.bubbleInnerVerticalPadding == 10)
        // Bubble row padding at 1.0× anchor.
        #expect(a.bubbleRowVerticalPadding == 4)
        // Assistant row padding at 1.0× anchor.
        #expect(a.assistantRowVerticalPadding == 2)
    }

    @Test("fontScale extremes resolve to the documented 0.80× / 1.20× body size")
    func fontScaleEndpointsScaleBodySize() {
        #expect(ChatAppearance(fontScale: 0.80).bodyFontSize == 19 * 0.80)
        #expect(ChatAppearance(fontScale: 1.20).bodyFontSize == 19 * 1.20)
    }

    @Test("intra-line leading em is the constant SSOT at every slider position")
    func leadingEmIsConstantSharedRatio() {
        // Leading no longer loosens with the slider — it's the shared
        // SuperTypography.readingLeadingEm at every position, so Chat and the
        // Bible reader keep one line rhythm (the gap still grows in points
        // because the body it multiplies grows; see lineSpacingPoints tests).
        for scale in [0.80, 1.00, 1.20] {
            #expect(ChatAppearance(fontScale: scale).paragraphLineSpacingEm == SuperTypography.readingLeadingEm)
        }
    }

    @Test("paragraph margin is a constant 16/17 em scaled by the body")
    func paragraphMarginScalesWithBody() {
        // Constant 16/17 em (≈0.94) × the 15.2 / 19 / 22.8pt body — the ratio is
        // fixed (≈0.76 of a line) so the top end no longer swells; only the body
        // it multiplies grows with the slider.
        #expect(abs(ChatAppearance(fontScale: 0.80).paragraphSpacing - 14.3059) < 0.0001)
        #expect(abs(ChatAppearance(fontScale: 1.00).paragraphSpacing - 17.8824) < 0.0001)
        #expect(abs(ChatAppearance(fontScale: 1.20).paragraphSpacing - 21.4588) < 0.0001)
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
        // Constant em (≈0.2353) × the 15.2 / 19 / 22.8pt body at 0.8× / 1.0× / 1.2×.
        #expect(abs(ChatAppearance(fontScale: 0.80).paragraphLineSpacingPoints - 3.5765) < 0.0001)
        #expect(abs(ChatAppearance(fontScale: 1.00).paragraphLineSpacingPoints - 4.4706) < 0.0001)
        #expect(abs(ChatAppearance(fontScale: 1.20).paragraphLineSpacingPoints - 5.3647) < 0.0001)
    }

    @Test("line-spacing-in-points grows monotonically with the font slider")
    func lineSpacingPointsIsMonotonic() {
        let small = ChatAppearance(fontScale: 0.80).paragraphLineSpacingPoints
        let mid = ChatAppearance(fontScale: 1.00).paragraphLineSpacingPoints
        let large = ChatAppearance(fontScale: 1.20).paragraphLineSpacingPoints
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
        // Halfway between 0.80 and 1.00 lands halfway between the low and mid
        // anchors on the interpolated axes (paragraph margin, bubble paddings);
        // the leading em is constant and ignores the slider.
        let halfwayLow = ChatAppearance(fontScale: 0.90)
        // Leading em is constant (not interpolated) — same at every slider position.
        #expect(halfwayLow.paragraphLineSpacingEm == SuperTypography.readingLeadingEm)
        // Constant 16/17 em × the 17.1pt body at 0.90×.
        #expect(abs(halfwayLow.paragraphSpacing - 16.0941) < 0.0001)
        // Halfway between 1.00 and 1.20 mirrors on the upper segment.
        let halfwayHigh = ChatAppearance(fontScale: 1.10)
        #expect(halfwayHigh.paragraphLineSpacingEm == SuperTypography.readingLeadingEm)
        #expect(abs(halfwayHigh.paragraphSpacing - 19.6706) < 0.0001)
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
