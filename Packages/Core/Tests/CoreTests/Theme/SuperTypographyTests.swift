import SwiftUI
import Testing
@testable import Core

// `SwiftUI.Font` equality is provider-sensitive, so assertions use `FontSpec`.
@Suite("SuperTypography resolution")
struct SuperTypographyTests {
    @Test("serif identity routes the display role to the brand face")
    func serifDisplay() {
        let t = SuperTypography.make(.serif)
        #expect(t.spec(size: 38, relativeTo: nil, weight: nil, design: .serif)
            == .init(face: "EBGaramond-Italic", size: 38, relativeTo: nil, weight: nil, design: .serif))
        #expect(t.spec(size: 36, relativeTo: .largeTitle, weight: nil, design: .serif)
            == .init(face: "EBGaramond-Italic", size: 36, relativeTo: .largeTitle, weight: nil, design: .serif))
    }

    @Test("system identity falls back to the system serif (no custom face)")
    func systemDisplay() {
        let t = SuperTypography.make(.system)
        #expect(t.spec(size: 38, relativeTo: .largeTitle, weight: nil, design: .serif)
            == .init(face: nil, size: 38, relativeTo: nil, weight: nil, design: .serif))
    }

    @Test("fontScale folds into the resolved size")
    func fontScaleFolds() {
        let serif = SuperTypography.make(.serif, fontScale: 2)
        #expect(serif.spec(size: 20, relativeTo: nil, weight: nil, design: .serif).size == 40)

        let sys = SuperTypography.make(.system, fontScale: 1.5)
        #expect(sys.spec(size: 17, relativeTo: nil, weight: nil, design: .default).size == 25.5)
    }

    @Test("tracksFontScale: false renders at the base size, ignoring the slider")
    func tracksFontScaleOptOut() {
        let serif = SuperTypography.make(.serif, fontScale: 2)
        #expect(serif.spec(size: 20, relativeTo: nil, weight: nil, design: .serif,
                           tracksFontScale: false).size == 20)
        // Slider opt-out must leave the custom face's Dynamic Type anchor intact.
        #expect(serif.spec(size: 11, relativeTo: .caption2, weight: nil, design: .monospaced,
                           tracksFontScale: false)
            == .init(face: "JetBrainsMono-Regular", size: 11, relativeTo: .caption2, weight: nil, design: .monospaced))

        let sys = SuperTypography.make(.system, fontScale: 1.5)
        #expect(sys.spec(size: 17, relativeTo: nil, weight: nil, design: .default,
                         tracksFontScale: false).size == 17)
        #expect(sys.spec(size: 17, relativeTo: nil, weight: nil, design: .default).size == 25.5)
    }

    @Test("system path drops relativeTo so it matches the literal .system call")
    func systemDropsRelativeTo() {
        let t = SuperTypography.make(.system)
        let spec = t.spec(size: 13, relativeTo: .footnote, weight: .medium, design: .default)
        #expect(spec == .init(face: nil, size: 13, relativeTo: nil, weight: .medium, design: .default))
    }

    @Test("mono routes to the brand face under serif, system mono otherwise")
    func monoResolution() {
        let serif = SuperTypography.make(.serif)
        #expect(serif.spec(size: 10.5, relativeTo: nil, weight: nil, design: .monospaced)
            == .init(face: "JetBrainsMono-Regular", size: 10.5, relativeTo: nil, weight: nil, design: .monospaced))

        let system = SuperTypography.make(.system)
        #expect(system.spec(size: 13, relativeTo: nil, weight: nil, design: .monospaced)
            == .init(face: nil, size: 13, relativeTo: nil, weight: nil, design: .monospaced))
    }

    @Test("display() accessor uses the largeTitle anchor by default")
    func displayAccessorDefaults() {
        let t = SuperTypography.make(.serif)
        let viaAccessor = t.spec(size: 36, relativeTo: .largeTitle, weight: nil, design: .serif)
        #expect(viaAccessor.face == "EBGaramond-Italic")
        #expect(viaAccessor.relativeTo == .largeTitle)
    }

    @Test("reading() routes to the roman body face, distinct from the italic display")
    func readingResolution() {
        let serif = SuperTypography.make(.serif)
        #expect(serif.readingSpec(size: 17, relativeTo: .body, weight: nil)
            == .init(face: "EBGaramond-Regular", size: 17, relativeTo: .body, weight: nil, design: .serif))
        #expect(serif.readingSpec(size: 15, relativeTo: nil, weight: .semibold).weight == .semibold)
        let scaled = SuperTypography.make(.serif, fontScale: 2)
        #expect(scaled.readingSpec(size: 16, relativeTo: nil, weight: nil).size == 32)
        #expect(scaled.readingSpec(size: 16, relativeTo: nil, weight: nil, tracksFontScale: false).size == 16)
        let sys = SuperTypography.make(.system)
        #expect(sys.readingSpec(size: 17, relativeTo: .body, weight: nil)
            == .init(face: nil, size: 17, relativeTo: nil, weight: nil, design: .serif))
    }

    @Test("serifFamily is the shared EB Garamond family name")
    func serifFamilyConstant() {
        #expect(SuperTypography.serifFamily == "EB Garamond")
    }

    @Test("readingFamily exposes the family name under serif, nil under system")
    func readingFamilyResolution() {
        #expect(SuperTypography.make(.serif).readingFamily == "EB Garamond")
        #expect(SuperTypography.make(.system).readingFamily == nil)
    }

    @Test("Role base sizes match Apple's text-style point sizes")
    func roleBaseSizes() {
        #expect(SuperTypography.Role.display.baseSize == 36)
        #expect(SuperTypography.Role.body.baseSize == 17)
        #expect(SuperTypography.Role.footnote.baseSize == 13)
        #expect(SuperTypography.Role.caption2.baseSize == 11)
    }

    @Test("readingBodySize is the shared SSOT for long-form reading body")
    func readingBodySizeIsSSOT() {
        #expect(SuperTypography.readingBodySize == 19)
        #expect(SuperTypography.readingBodySize != SuperTypography.Role.body.baseSize)
    }

    @Test("readingLeadingEm is the shared intra-line leading ratio (4/17)")
    func readingLeadingEmIsSSOT() {
        let expected: CGFloat = 4.0 / 17.0
        #expect(abs(SuperTypography.readingLeadingEm - expected) < 1e-12)
    }

    @Test("font(_:weight:) threads weight through every role, including display")
    func fontRoleThreadsWeight() {
        // Regression: the .display branch previously routed through display(),
        // which hardcoded weight: nil and silently dropped a caller's weight.
        let t = SuperTypography.make(.serif)
        let display = t.spec(size: SuperTypography.Role.display.baseSize,
                             relativeTo: .largeTitle, weight: .bold, design: .serif)
        #expect(display.weight == .bold)
        #expect(display.face == "EBGaramond-Italic")

        let body = t.spec(size: SuperTypography.Role.body.baseSize,
                          relativeTo: nil, weight: .semibold, design: .default)
        #expect(body.weight == .semibold)
    }
}
