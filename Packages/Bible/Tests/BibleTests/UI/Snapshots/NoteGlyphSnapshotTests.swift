#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `NoteGlyph` — the folded-page glyph that marks a target
/// as carrying notes. The `.filled` silhouette is captured across the
/// three themes (the colors are theme-driven); `.outline` is the
/// construction / empty-state variant and differs only in stroke-vs-fill,
/// fully captured by the light pass.
@Suite("NoteGlyph snapshots")
@MainActor
struct NoteGlyphSnapshotTests {
    @Test("filled glyph renders in the light theme")
    func filledLight() {
        verify(theme: .light, state: .filled, name: "filled_light")
    }

    @Test("filled glyph renders in the dark theme")
    func filledDark() {
        verify(theme: .dark, state: .filled, name: "filled_dark")
    }

    @Test("filled glyph renders in the sepia theme")
    func filledSepia() {
        verify(theme: .sepia, state: .filled, name: "filled_sepia")
    }

    @Test("outline glyph renders in the light theme")
    func outlineLight() {
        verify(theme: .light, state: .outline, name: "outline_light")
    }

    @Test("outline glyph renders in the dark theme")
    func outlineDark() {
        verify(theme: .dark, state: .outline, name: "outline_dark")
    }

    @Test("outline glyph renders in the sepia theme")
    func outlineSepia() {
        verify(theme: .sepia, state: .outline, name: "outline_sepia")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        state: NoteGlyph.GlyphState,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        // Render at 48pt on a 96×96 field (3× the production trailing size)
        // so the fold cut and ruled lines are inspectable by eye.
        let view = ZStack {
            theme.background
            NoteGlyph(state: state, size: 48)
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
