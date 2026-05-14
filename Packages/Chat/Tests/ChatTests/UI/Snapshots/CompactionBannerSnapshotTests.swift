#if canImport(UIKit)
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for `CompactionBanner` in both collapsed and expanded states.
/// The collapsed state pins the 3-line truncation + "Show more" caption;
/// the expanded state pins the full multi-paragraph rendering driven by
/// the `initiallyExpanded` test seam (the state is otherwise toggled only
/// via tap, which snapshot tests can't drive).
@Suite("CompactionBanner snapshots", .serialized)
@MainActor
struct CompactionBannerSnapshotTests {
    /// A summary long enough to overflow the 3-line collapsed cap so the
    /// truncation + expand affordance is exercised. Mirrors the 3–8
    /// sentence shape `Compactor`'s summarization prompt asks for.
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
        verify(initiallyExpanded: false, theme: .light, name: "compaction_collapsed_light")
    }

    @Test("collapsed banner in dark theme")
    func collapsedDark() {
        verify(initiallyExpanded: false, theme: .dark, name: "compaction_collapsed_dark")
    }

    @Test("expanded banner in light theme")
    func expandedLight() {
        verify(initiallyExpanded: true, theme: .light, name: "compaction_expanded_light")
    }

    @Test("expanded banner in dark theme")
    func expandedDark() {
        verify(initiallyExpanded: true, theme: .dark, name: "compaction_expanded_dark")
    }

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

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 360)),
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
