import Core
import SwiftUI
import Testing
@testable import Chat

@Suite("ChatAppearance")
struct ChatAppearanceTests {
    @Test("default appearance matches the documented Claude-tuned values")
    func defaultMatchesDocumentedDefaults() {
        let a = ChatAppearance.default
        #expect(a.fontScale == 1.0)
        #expect(a.bodyFontSize == 19)
        #expect(a.paragraphLineSpacingEm == SuperTypography.readingLeadingEm)
        #expect(abs(a.paragraphSpacing - 17.8824) < 0.0001)
        #expect(a.bubbleInnerVerticalPadding == 10)
        #expect(a.bubbleRowVerticalPadding == 4)
        #expect(a.assistantRowVerticalPadding == 2)
    }

    @Test("fontScale extremes resolve to the documented 0.80× / 1.20× body size")
    func fontScaleEndpointsScaleBodySize() {
        #expect(ChatAppearance(fontScale: 0.80).bodyFontSize == 19 * 0.80)
        #expect(ChatAppearance(fontScale: 1.20).bodyFontSize == 19 * 1.20)
    }

    // Pass scale to Core so both sides derive identical metrics at every slider position.
    @Test("markdownMetrics projection matches Core's metrics at every slider position")
    func markdownMetricsProjectionParity() {
        #expect(ChatAppearance.default.markdownMetrics == MarkdownBodyMetrics.default)
        for scale: Double in [0.80, 0.90, 1.00, 1.05, 1.10, 1.20] {
            let appearance = ChatAppearance(fontScale: scale)
            let metrics = appearance.markdownMetrics
            // Normalize numeric types because mixed Double/CGFloat equality misbehaves inside #expect.
            #expect(metrics.fontScale == CGFloat(appearance.fontScale))
            #expect(metrics.bodyFontSize == appearance.bodyFontSize)
            #expect(metrics.paragraphLineSpacingEm == appearance.paragraphLineSpacingEm)
            #expect(metrics.paragraphLineSpacingPoints == appearance.paragraphLineSpacingPoints)
            #expect(metrics.paragraphSpacing == appearance.paragraphSpacing)
        }
    }

    @Test("intra-line leading em is the constant SSOT at every slider position")
    func leadingEmIsConstantSharedRatio() {
        for scale in [0.80, 1.00, 1.20] {
            #expect(ChatAppearance(fontScale: scale).paragraphLineSpacingEm == SuperTypography.readingLeadingEm)
        }
    }

    @Test("paragraph margin is a constant 16/17 em scaled by the body")
    func paragraphMarginScalesWithBody() {
        #expect(abs(ChatAppearance(fontScale: 0.80).paragraphSpacing - 14.3059) < 0.0001)
        #expect(abs(ChatAppearance(fontScale: 1.00).paragraphSpacing - 17.8824) < 0.0001)
        #expect(abs(ChatAppearance(fontScale: 1.20).paragraphSpacing - 21.4588) < 0.0001)
    }

    @Test("line-spacing-in-points equals the em line spacing resolved against body size")
    func lineSpacingPointsResolvesEmAgainstBody() {
        for scale in [0.80, 0.90, 1.00, 1.10, 1.20] {
            let a = ChatAppearance(fontScale: scale)
            #expect(a.paragraphLineSpacingPoints == a.paragraphLineSpacingEm * a.bodyFontSize)
        }
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
        let halfwayLow = ChatAppearance(fontScale: 0.90)
        #expect(halfwayLow.paragraphLineSpacingEm == SuperTypography.readingLeadingEm)
        #expect(abs(halfwayLow.paragraphSpacing - 16.0941) < 0.0001)
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
