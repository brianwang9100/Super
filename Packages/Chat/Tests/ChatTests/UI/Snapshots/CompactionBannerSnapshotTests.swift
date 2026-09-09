#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("CompactionBanner snapshots", .serialized)
@MainActor
struct CompactionBannerSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }
    private let longSummary: String = """
        User asked for a Lisbon long-weekend itinerary; assistant suggested \
        booking the Belém pastry shop in advance, riding tram 28, and \
        carrying a transit card. They also discussed which neighborhoods \
        to stay in (Alfama vs Chiado), settled on Chiado for walkability, \
        and queued up sunset spots at Miradouro da Senhora do Monte. \
        Outstanding question: whether to swap Sintra for Cascais on the \
        day trip — depends on weather.
        """

    @Test("collapsed banner in light theme")
    func collapsedLight() {
        verify(initiallyExpanded: false, theme: .vellumLight, name: "compaction_collapsed_light")
    }

    @Test("collapsed banner in dark theme")
    func collapsedDark() {
        verify(initiallyExpanded: false, theme: .vellumDark, name: "compaction_collapsed_dark")
    }

    @Test("expanded banner in light theme")
    func expandedLight() {
        verify(initiallyExpanded: true, theme: .vellumLight, name: "compaction_expanded_light")
    }

    @Test("expanded banner in dark theme")
    func expandedDark() {
        verify(initiallyExpanded: true, theme: .vellumDark, name: "compaction_expanded_dark")
    }

    // Collapse/expand animation has the same settled frames with Reduce Motion.

    private func verify(
        initiallyExpanded: Bool,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = CompactionBanner(
            summary: longSummary,
            initiallyExpanded: initiallyExpanded
        )
        .superTheme(.make(theme))
        .padding(.horizontal, 12)
        .frame(width: 402, height: 360)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 360)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
