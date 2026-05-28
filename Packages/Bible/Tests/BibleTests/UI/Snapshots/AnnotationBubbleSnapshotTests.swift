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

    /// Three filled bubbles side-by-side — the composition `BibleChapterReader`
    /// uses in PR3 when multiple overlapping verse-range annotations share a
    /// `verseEnd` (per `ANNOTATIONS.md` §5). The 3-pt gap and inline-flex
    /// arrangement match the JSX `screens.jsx` `trailingCount` block. The
    /// snapshot guards the per-bubble spacing contract so PR3 can layer the
    /// stack directly without re-deriving the metrics.
    @Test("three bubbles stack horizontally after one verse")
    func multiStackLight() {
        let theme = SuperTheme.make(.light)
        let view = ZStack {
            theme.background
            HStack(spacing: 3) {
                AnnotationBubble(state: .filled, size: 24)
                AnnotationBubble(state: .filled, size: 24)
                AnnotationBubble(state: .filled, size: 24)
            }
        }
        .frame(width: 144, height: 64)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 144, height: 64)),
            named: "multi_stack_light",
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: #function
        )
        if let failure {
            Issue.record("multi_stack_light: \(failure)")
        }
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        state: AnnotationBubble.BubbleState,
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
