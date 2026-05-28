#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `AnnotationBubble` — the speech-bubble glyph in each of
/// its three states (`.empty`, `.generating`, `.filled`) and across the
/// three themes for the filled silhouette (the colors come from the
/// theme; the other two states differ only in stroke vs fill, which is
/// fully captured by the light variant).
@Suite("AnnotationBubble snapshots")
@MainActor
struct AnnotationBubbleSnapshotTests {
    @Test("filled bubble renders in the light theme")
    func filledLight() {
        verify(theme: .light, state: .filled, name: "filled_light")
    }

    @Test("filled bubble renders in the dark theme")
    func filledDark() {
        verify(theme: .dark, state: .filled, name: "filled_dark")
    }

    @Test("filled bubble renders in the sepia theme")
    func filledSepia() {
        verify(theme: .sepia, state: .filled, name: "filled_sepia")
    }

    @Test("empty bubble renders in the light theme")
    func emptyLight() {
        verify(theme: .light, state: .empty, name: "empty_light")
    }

    @Test("generating bubble renders in the light theme")
    func generatingLight() {
        verify(theme: .light, state: .generating, name: "generating_light")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        state: AnnotationBubble.State,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        // Render at 64×64 (4× the production 16pt size) so anti-aliasing
        // and the bottom-left tail are easy to inspect by eye in the
        // baseline image.
        let view = ZStack {
            theme.background
            AnnotationBubble(state: state, size: 48)
        }
        .frame(width: 96, height: 96)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 96, height: 96)),
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
