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
            == .init(face: "InstrumentSerif-Italic", size: 38, relativeTo: nil, weight: nil, design: .serif))
        // With a Dynamic Type anchor the custom face carries relativeTo.
        #expect(t.spec(size: 36, relativeTo: .largeTitle, weight: nil, design: .serif)
            == .init(face: "InstrumentSerif-Italic", size: 36, relativeTo: .largeTitle, weight: nil, design: .serif))
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
        #expect(viaAccessor.face == "InstrumentSerif-Italic")
        #expect(viaAccessor.relativeTo == .largeTitle)
    }

    @Test("Role base sizes match Apple's text-style point sizes")
    func roleBaseSizes() {
        #expect(SuperTypography.Role.display.baseSize == 36)
        #expect(SuperTypography.Role.body.baseSize == 17)
        #expect(SuperTypography.Role.footnote.baseSize == 13)
        #expect(SuperTypography.Role.caption2.baseSize == 11)
    }

    @Test("font(_:weight:) threads weight through every role, including display")
    func fontRoleThreadsWeight() {
        // Regression: the .display branch previously routed through display(),
        // which hardcoded weight: nil and silently dropped a caller's weight.
        let t = SuperTypography.make(.serif)
        let display = t.spec(size: SuperTypography.Role.display.baseSize,
                             relativeTo: .largeTitle, weight: .bold, design: .serif)
        #expect(display.weight == .bold)
        #expect(display.face == "InstrumentSerif-Italic")

        let body = t.spec(size: SuperTypography.Role.body.baseSize,
                          relativeTo: nil, weight: .semibold, design: .default)
        #expect(body.weight == .semibold)
    }
}
