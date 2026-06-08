#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for `SourceCitationsPill` — the collapsible "N sources" chip
/// rendered under a grounded assistant answer. Collapsed pins the chip-only
/// shape ("3 sources" + chevron); expanded pins the per-source list (domain +
/// truncated title). Light / dark / sepia cover the themes; a singular-count
/// case pins the "1 source" copy; a Dynamic Type XXL case pins text reflow.
///
/// `.serialized` for the same TOCTOU reason as every other snapshot suite
/// here (parallel writes race on the `__Snapshots__/` PNGs, not on code
/// under test). Reduce Motion is not a separate variant: the pill toggles
/// `isExpanded` via a plain `Button` action with no `withAnimation`/
/// `.animation(...)`, so steady-state collapsed/expanded frames are
/// identical regardless of `accessibilityReduceMotion`.
@Suite("SourceCitationsPill snapshots", .serialized)
@MainActor
struct SourceCitationsPillSnapshotTests {
    /// Register Core's bundled brand fonts before any render so this suite
    /// is order-independent in the shared test process (the xctest host never
    /// runs the app's font registration). See SnapshotFontRegistration.
    init() { SnapshotFontRegistration.ensureRegistered() }
    private static let threeSources: [SourceCitationPillModel] = [
        SourceCitationPillModel(
            id: "1", title: "Perseverance finds organic molecules in Jezero crater",
            host: "nasa.gov", url: URL(string: "https://www.nasa.gov/mars")!
        ),
        SourceCitationPillModel(
            id: "2", title: "Mars rover update: water ice confirmed",
            host: "space.com", url: URL(string: "https://www.space.com/rover")!
        ),
        SourceCitationPillModel(
            id: "3", title: "What the latest Mars findings mean",
            host: "scientificamerican.com", url: URL(string: "https://www.scientificamerican.com/mars")!
        ),
    ]

    @Test("collapsed, three sources, light")
    func collapsedLight() {
        verify(sources: Self.threeSources, expanded: false, theme: .vellumLight, height: 80, name: "sources_pill_collapsed_light")
    }

    @Test("collapsed, three sources, dark")
    func collapsedDark() {
        verify(sources: Self.threeSources, expanded: false, theme: .vellumDark, height: 80, name: "sources_pill_collapsed_dark")
    }

    @Test("expanded, three sources, light")
    func expandedLight() {
        verify(sources: Self.threeSources, expanded: true, theme: .vellumLight, height: 240, name: "sources_pill_expanded_light")
    }

    @Test("expanded, three sources, dark")
    func expandedDark() {
        verify(sources: Self.threeSources, expanded: true, theme: .vellumDark, height: 240, name: "sources_pill_expanded_dark")
    }

    @Test("expanded, single source, light (singular copy)")
    func expandedSingleLight() {
        verify(
            sources: [Self.threeSources[0]], expanded: true, theme: .vellumLight, height: 120,
            name: "sources_pill_expanded_single_light"
        )
    }

    @Test("expanded dynamic type XXL")
    func expandedXXL() {
        verify(
            sources: Self.threeSources, expanded: true, theme: .vellumLight, dynamicType: .xxLarge, height: 360,
            name: "sources_pill_expanded_light_xxl"
        )
    }

    private func verify(
        sources: [SourceCitationPillModel],
        expanded: Bool,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat,
        name: String,
        function: String = #function
    ) {
        let view = SourceCitationsPill(sources: sources, _isExpanded: expanded)
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(width: 402, height: height)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: height)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}

#endif
