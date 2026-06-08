import CoreGraphics
import Testing
@testable import Bible

/// Tests for `BibleReadingMetrics` — pins the reading-surface spacing ratios
/// against a 17pt *reference* body (the ratio denominators `4/17` and `10/17`),
/// where they resolve to exactly 3.2/4/4.8pt line gap and 8/10/12pt paragraph
/// margin at 0.8×/1.0×/1.2× — the cleanest check of the ratio constants. The
/// production default body is now 19pt (`SuperTypography.readingBodySize`), at
/// which the gaps scale up proportionally (≈4.47/11.18pt at 1.0×). The
/// monotonic checks guard a future ratio tweak; division is written last in the
/// formula so the reference anchors stay pixel-stable.
@Suite("BibleReadingMetrics")
struct BibleReadingMetricsTests {
    /// The 17pt reference body the ratio denominators are authored against, so
    /// the anchors resolve to whole points. (Production renders a 19pt body.)
    private let referenceBody: CGFloat = 17

    @Test("line gap resolves to 3.2/4/4.8pt at the 0.8×/1.0×/1.2× slider anchors")
    func lineSpacingAnchors() {
        #expect(BibleReadingMetrics.lineSpacing(bodySize: referenceBody, fontScale: 0.8) == 3.2)
        #expect(BibleReadingMetrics.lineSpacing(bodySize: referenceBody, fontScale: 1.0) == 4)
        #expect(BibleReadingMetrics.lineSpacing(bodySize: referenceBody, fontScale: 1.2) == 4.8)
    }

    @Test("paragraph margin resolves to 8/10/12pt at the 0.8×/1.0×/1.2× slider anchors")
    func paragraphSpacingAnchors() {
        #expect(BibleReadingMetrics.paragraphSpacing(bodySize: referenceBody, fontScale: 0.8) == 8)
        #expect(BibleReadingMetrics.paragraphSpacing(bodySize: referenceBody, fontScale: 1.0) == 10)
        #expect(BibleReadingMetrics.paragraphSpacing(bodySize: referenceBody, fontScale: 1.2) == 12)
    }

    @Test("the 1.0× ratio resolves to exactly 4pt / 10pt over the 17pt reference — no sub-ULP drift")
    func defaultIsExact() {
        #expect(BibleReadingMetrics.lineSpacing(bodySize: referenceBody, fontScale: 1.0) == 4.0)
        #expect(BibleReadingMetrics.paragraphSpacing(bodySize: referenceBody, fontScale: 1.0) == 10.0)
    }

    @Test("both gaps grow monotonically with the font slider")
    func gapsAreMonotonic() {
        let lineSmall = BibleReadingMetrics.lineSpacing(bodySize: referenceBody, fontScale: 0.8)
        let lineMid = BibleReadingMetrics.lineSpacing(bodySize: referenceBody, fontScale: 1.0)
        let lineLarge = BibleReadingMetrics.lineSpacing(bodySize: referenceBody, fontScale: 1.2)
        #expect(lineSmall < lineMid)
        #expect(lineMid < lineLarge)

        let paraSmall = BibleReadingMetrics.paragraphSpacing(bodySize: referenceBody, fontScale: 0.8)
        let paraMid = BibleReadingMetrics.paragraphSpacing(bodySize: referenceBody, fontScale: 1.0)
        let paraLarge = BibleReadingMetrics.paragraphSpacing(bodySize: referenceBody, fontScale: 1.2)
        #expect(paraSmall < paraMid)
        #expect(paraMid < paraLarge)
    }

    @Test("OS Dynamic Type composes on top of the slider via bodySize")
    func dynamicTypeComposesWithSlider() {
        // A larger @ScaledMetric body (Dynamic Type bumped up) widens the gap
        // even at the same slider position — both axes multiply in.
        let base = BibleReadingMetrics.lineSpacing(bodySize: 17, fontScale: 1.0)
        let larger = BibleReadingMetrics.lineSpacing(bodySize: 34, fontScale: 1.0)
        #expect(larger == base * 2)
    }
}
