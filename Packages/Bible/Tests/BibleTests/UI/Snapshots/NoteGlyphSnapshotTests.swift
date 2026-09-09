#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Filled variants cover theme colors; the outline-only shape difference needs one theme.
@Suite("NoteGlyph snapshots", .serialized)
@MainActor
struct NoteGlyphSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("filled glyph renders in the light theme")
    func filledLight() {
        verify(theme: .vellumLight, state: .filled, name: "filled_light")
    }

    @Test("filled glyph renders in the dark theme")
    func filledDark() {
        verify(theme: .vellumDark, state: .filled, name: "filled_dark")
    }

    @Test("outline glyph renders in the light theme")
    func outlineLight() {
        verify(theme: .vellumLight, state: .outline, name: "outline_light")
    }

    @Test("outline glyph renders in the dark theme")
    func outlineDark() {
        verify(theme: .vellumDark, state: .outline, name: "outline_dark")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        state: NoteGlyph.GlyphState,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        // Enlarge the glyph so fold and ruling details remain inspectable.
        let view = ZStack {
            theme.background
            NoteGlyph(state: state, size: 48)
        }
        .frame(width: 96, height: 96)
        .superTheme(theme)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 96, height: 96)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
