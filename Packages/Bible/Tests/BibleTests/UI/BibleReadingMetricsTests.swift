import CoreGraphics
import Testing
@testable import Bible

@Suite("BibleReadingMetrics")
struct BibleReadingMetricsTests {
    // Ratios are authored against 17pt; production uses 19pt. Keep exact reference anchors here.
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
        let base = BibleReadingMetrics.lineSpacing(bodySize: 17, fontScale: 1.0)
        let larger = BibleReadingMetrics.lineSpacing(bodySize: 34, fontScale: 1.0)
        #expect(larger == base * 2)
    }
}
