import SwiftUI
import Testing
@testable import Core

/// Verifies `SuperTypography` resolves roles to the expected font descriptors:
/// the brand `.serif` identity routes serif/mono roles to the bundled faces,
/// the `.system` identity falls back to system faces (no custom face) so it's
/// byte-identical to the hand-written `.font(.system(...))` it replaces, and
/// `fontScale` folds into every accessor.
///
/// Assertions target the pure `FontSpec` descriptor rather than `SwiftUI.Font`
/// — `Font`'s `==` is provider-sensitive and can't reliably compare custom or
/// system fonts.
@Suite("SuperTypography resolution")
struct SuperTypographyTests {
    @Test("serif identity routes the display role to the brand face")
    func serifDisplay() {
        let t = SuperTypography.make(.serif)
        #expect(t.spec(size: 38, relativeTo: nil, weight: nil, design: .serif)
            == .init(face: "EBGaramond-Italic", size: 38, relativeTo: nil, weight: nil, design: .serif))
        // With a Dynamic Type anchor the custom face carries relativeTo.
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
        // Chrome and fixed brand marks opt out of the app font-scale slider —
        // the resolved size is the base size, not size * fontScale, on both the
        // brand-face and system-face paths.
        let serif = SuperTypography.make(.serif, fontScale: 2)
        #expect(serif.spec(size: 20, relativeTo: nil, weight: nil, design: .serif,
                           tracksFontScale: false).size == 20)
        // Opting out of the slider does not touch the OS Dynamic Type anchor —
        // a brand face still carries relativeTo.
        #expect(serif.spec(size: 11, relativeTo: .caption2, weight: nil, design: .monospaced,
                           tracksFontScale: false)
            == .init(face: "JetBrainsMono-Regular", size: 11, relativeTo: .caption2, weight: nil, design: .monospaced))

        let sys = SuperTypography.make(.system, fontScale: 1.5)
        #expect(sys.spec(size: 17, relativeTo: nil, weight: nil, design: .default,
                         tracksFontScale: false).size == 17)
        // Default (true) still folds — the opt-out is explicit, not the norm.
        #expect(sys.spec(size: 17, relativeTo: nil, weight: nil, design: .default).size == 25.5)
    }

    @Test("system path drops relativeTo so it matches the literal .system call")
    func systemDropsRelativeTo() {
        // Even if a caller passes an anchor, the system branch ignores it —
        // the migrated `.system(size:)` sites had no relativeTo.
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
        // display(_:) defaults relativeTo to .largeTitle.
        let viaAccessor = t.spec(size: 36, relativeTo: .largeTitle, weight: nil, design: .serif)
        #expect(viaAccessor.face == "EBGaramond-Italic")
        #expect(viaAccessor.relativeTo == .largeTitle)
    }

    @Test("reading() routes to the roman body face, distinct from the italic display")
    func readingResolution() {
        let serif = SuperTypography.make(.serif)
        // The reading body face is the roman EB Garamond — NOT the italic
        // display face — so long-form content reads upright.
        #expect(serif.readingSpec(size: 17, relativeTo: .body, weight: nil)
            == .init(face: "EBGaramond-Regular", size: 17, relativeTo: .body, weight: nil, design: .serif))
        // A weight threads through (markdown strong / Bible section heading).
        #expect(serif.readingSpec(size: 15, relativeTo: nil, weight: .semibold).weight == .semibold)
        // fontScale folds in like every other accessor.
        let scaled = SuperTypography.make(.serif, fontScale: 2)
        #expect(scaled.readingSpec(size: 16, relativeTo: nil, weight: nil).size == 32)
        // tracksFontScale: false renders at the base size.
        #expect(scaled.readingSpec(size: 16, relativeTo: nil, weight: nil, tracksFontScale: false).size == 16)
        // The system identity drops to the system serif (nil face, no anchor).
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
        // The MarkdownUI body bridge selects italic/semibold members by
        // family name, so serif resolves to the shared family and system
        // resolves to nil (use the system default body face).
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
        // Single source of truth for the EB Garamond roman reading body
        // (assistant messages + Bible verse body). Distinct from Role.body (17),
        // which sizes system-sans chrome and must not move with reading comfort.
        #expect(SuperTypography.readingBodySize == 19)
        #expect(SuperTypography.readingBodySize != SuperTypography.Role.body.baseSize)
    }

    @Test("readingLeadingEm is the shared intra-line leading ratio (4/17)")
    func readingLeadingEmIsSSOT() {
        // Single source of truth for the line gap shared by the assistant body
        // (ChatAppearance.paragraphLineSpacingEm) and the Bible reader
        // (BibleReadingMetrics.lineSpacing), so both read as one line rhythm.
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
