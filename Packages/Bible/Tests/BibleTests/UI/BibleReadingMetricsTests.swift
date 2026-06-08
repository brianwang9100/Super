import CoreGraphics
import Testing
@testable import Bible

/// Tests for `BibleReadingMetrics` — pins the reading-surface spacing anchors
/// (3.2/4/4.8pt line gap, 8/10/12pt paragraph margin at 0.8×/1.0×/1.2× over the
/// 17pt default body) and verifies the gaps scale monotonically with the font
/// slider, so a future ratio tweak is caught here rather than only by
/// re-recorded snapshots. The 1.0× default resolves to exactly 4/10 — division
/// is written last in the formula precisely so these stay pixel-stable.
@Suite("BibleReadingMetrics")
struct BibleReadingMetricsTests {
    /// The rendered body point size at the default content-size category —
    /// the `@ScaledMetric(.body)` base the call sites feed in.
    private let defaultBody: CGFloat = 17

    @Test("line gap resolves to 3.2/4/4.8pt at the 0.8×/1.0×/1.2× slider anchors")
    func lineSpacingAnchors() {
        #expect(BibleReadingMetrics.lineSpacing(bodySize: defaultBody, fontScale: 0.8) == 3.2)
        #expect(BibleReadingMetrics.lineSpacing(bodySize: defaultBody, fontScale: 1.0) == 4)
        #expect(BibleReadingMetrics.lineSpacing(bodySize: defaultBody, fontScale: 1.2) == 4.8)
    }

    @Test("paragraph margin resolves to 8/10/12pt at the 0.8×/1.0×/1.2× slider anchors")
    func paragraphSpacingAnchors() {
        #expect(BibleReadingMetrics.paragraphSpacing(bodySize: defaultBody, fontScale: 0.8) == 8)
        #expect(BibleReadingMetrics.paragraphSpacing(bodySize: defaultBody, fontScale: 1.0) == 10)
        #expect(BibleReadingMetrics.paragraphSpacing(bodySize: defaultBody, fontScale: 1.2) == 12)
    }

    @Test("the 1.0× default resolves to exactly 4pt / 10pt — no sub-ULP drift")
    func defaultIsExact() {
        #expect(BibleReadingMetrics.lineSpacing(bodySize: defaultBody, fontScale: 1.0) == 4.0)
        #expect(BibleReadingMetrics.paragraphSpacing(bodySize: defaultBody, fontScale: 1.0) == 10.0)
    }

    @Test("both gaps grow monotonically with the font slider")
    func gapsAreMonotonic() {
        let lineSmall = BibleReadingMetrics.lineSpacing(bodySize: defaultBody, fontScale: 0.8)
        let lineMid = BibleReadingMetrics.lineSpacing(bodySize: defaultBody, fontScale: 1.0)
        let lineLarge = BibleReadingMetrics.lineSpacing(bodySize: defaultBody, fontScale: 1.2)
        #expect(lineSmall < lineMid)
        #expect(lineMid < lineLarge)

        let paraSmall = BibleReadingMetrics.paragraphSpacing(bodySize: defaultBody, fontScale: 0.8)
        let paraMid = BibleReadingMetrics.paragraphSpacing(bodySize: defaultBody, fontScale: 1.0)
        let paraLarge = BibleReadingMetrics.paragraphSpacing(bodySize: defaultBody, fontScale: 1.2)
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
