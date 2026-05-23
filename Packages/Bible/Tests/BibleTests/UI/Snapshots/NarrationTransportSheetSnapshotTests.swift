#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of ``NarrationTransportSheet`` — the inline overlay card
/// that hosts the full Narrate transport. Covers the three themes
/// against the three state variants the user encounters (speaking,
/// paused, and idle-after-Stop). The idle snapshot is the only place
/// where the play button reads as `Restart narration` and the Stop
/// button is dimmed — both consequences of the
/// `Stop-keeps-the-card-open` rule. A Dynamic Type XXL variant guards
/// against squeezed labels in the header citation and dropdown chips.
@Suite("NarrationTransportSheet snapshots")
@MainActor
struct NarrationTransportSheetSnapshotTests {
    @Test("the transport card renders while speaking in the light theme")
    func speakingLight() async {
        await verify(theme: .light, state: .speaking, currentVerse: 9, name: "speaking_light")
    }

    @Test("the transport card renders while speaking in the dark theme")
    func speakingDark() async {
        await verify(theme: .dark, state: .speaking, currentVerse: 9, name: "speaking_dark")
    }

    @Test("the transport card renders while speaking in the sepia theme")
    func speakingSepia() async {
        await verify(theme: .sepia, state: .speaking, currentVerse: 9, name: "speaking_sepia")
    }

    @Test("the transport card renders while paused in the light theme")
    func pausedLight() async {
        await verify(theme: .light, state: .paused, currentVerse: 9, name: "paused_light")
    }

    @Test("the transport card renders at Dynamic Type XXL in the light theme")
    func speakingLightDTXXL() async {
        await verify(
            theme: .light, state: .speaking, currentVerse: 9,
            name: "speaking_light_dt_xxl", dynamicType: .xxLarge
        )
    }

    @Test("the transport card renders post-Stop with Stop dimmed and play enabled")
    func idleLight() async {
        // Verifies the Stop-keeps-the-card rule: the card stays up
        // after Stop, the stop button reads as disabled (so the user
        // can't no-op it), and the big play button is still tappable
        // — calling it triggers the `onRestart` callback the screen
        // wires to a fresh Narrate run.
        await verify(theme: .light, state: .idle, currentVerse: 5, name: "idle_light")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        state: NarrationController.State,
        currentVerse: Int,
        name: String,
        dynamicType: DynamicTypeSize = .large,
        function: String = #function
    ) async {
        let theme = SuperTheme.make(themeID)
        let service = FakeNarrationService()
        let controller = NarrationController(service: service)
        // For the .idle case skip the start/emit dance — a fresh
        // controller is already in .idle.
        if state != .idle {
            controller.start(utterances: [
                NarrationVerseUtterance(verseNumber: currentVerse, text: "scripture text"),
            ])
            service.emit(.started(verseNumber: currentVerse))
            await yieldUntil { controller.state == .speaking }
            if state == .paused {
                service.emit(.paused)
                await yieldUntil { controller.state == .paused }
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

    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
        }
    }
}
#endif
