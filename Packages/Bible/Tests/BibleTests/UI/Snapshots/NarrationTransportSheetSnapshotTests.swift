#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of ``NarrationTransportSheet`` — the inline overlay card
/// that hosts the full Narrate transport. Covers all three states the
/// user encounters (speaking, paused, and idle-after-Stop) across all
/// three themes, plus a Dynamic Type XXL variant in light that guards
/// against squeezed labels in the header citation and dropdown chips.
///
/// State-bearing snapshots are driven via the controller's
/// `_simulateEvent(_:)` test seam instead of yielding through the
/// fake's `AsyncStream` + polling for the consumer Task to wake —
/// per root AGENTS.md §Testing.2.
@Suite("NarrationTransportSheet snapshots")
@MainActor
struct NarrationTransportSheetSnapshotTests {
    @Test("the transport card renders while speaking in the light theme")
    func speakingLight() {
        verify(theme: .light, state: .speaking, currentVerse: 9, name: "speaking_light")
    }

    @Test("the transport card renders while speaking in the dark theme")
    func speakingDark() {
        verify(theme: .dark, state: .speaking, currentVerse: 9, name: "speaking_dark")
    }

    @Test("the transport card renders while speaking in the sepia theme")
    func speakingSepia() {
        verify(theme: .sepia, state: .speaking, currentVerse: 9, name: "speaking_sepia")
    }

    @Test("the transport card renders while paused in the light theme")
    func pausedLight() {
        verify(theme: .light, state: .paused, currentVerse: 9, name: "paused_light")
    }

    @Test("the transport card renders while paused in the dark theme")
    func pausedDark() {
        verify(theme: .dark, state: .paused, currentVerse: 9, name: "paused_dark")
    }

    @Test("the transport card renders while paused in the sepia theme")
    func pausedSepia() {
        verify(theme: .sepia, state: .paused, currentVerse: 9, name: "paused_sepia")
    }

    @Test("the transport card renders at Dynamic Type XXL in the light theme")
    func speakingLightDTXXL() {
        verify(
            theme: .light, state: .speaking, currentVerse: 9,
            name: "speaking_light_dt_xxl", dynamicType: .xxLarge
        )
    }

    @Test("the transport card renders post-Stop with Stop dimmed and play enabled in the light theme")
    func idleLight() {
        // Verifies the Stop-keeps-the-card rule: the card stays up
        // after Stop, the stop button reads as disabled (so the user
        // can't no-op it), and the big play button is still tappable
        // — calling it triggers the `onRestart` callback the screen
        // wires to a fresh Narrate run.
        verify(theme: .light, state: .idle, currentVerse: 5, name: "idle_light")
    }

    @Test("the post-Stop idle state renders in the dark theme")
    func idleDark() {
        verify(theme: .dark, state: .idle, currentVerse: 5, name: "idle_dark")
    }

    @Test("the post-Stop idle state renders in the sepia theme")
    func idleSepia() {
        verify(theme: .sepia, state: .idle, currentVerse: 5, name: "idle_sepia")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        state: NarrationController.State,
        currentVerse: Int,
        name: String,
        dynamicType: DynamicTypeSize = .large,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        // For the .idle case skip the start/emit dance — a fresh
        // controller is already in .idle.
        if state != .idle {
            controller.start(utterances: [
                NarrationVerseUtterance(verseNumber: currentVerse, text: "scripture text"),
            ])
            controller._simulateEvent(.started(verseNumber: currentVerse))
            if state == .paused {
                controller._simulateEvent(.paused)
            }
        }

        let view = NarrationTransportSheet(
            controller: controller,
            citation: "Song of Solomon 6:\(currentVerse) (WEB)",
            onStop: {},
            onRestart: {},
            onDismiss: {}
        )
        // The card is rendered inside a container with 12pt horizontal
        // padding on the production screen, so account for that here so
        // the snapshot matches what users actually see.
        .padding(.horizontal, 12)
        .frame(width: 402, height: 320)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 320)),
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
