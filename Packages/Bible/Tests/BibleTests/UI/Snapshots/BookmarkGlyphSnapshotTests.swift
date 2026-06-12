#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BookmarkGlyph` — the ribbon glyph marking a bookmarked
/// chapter. One palette strip per theme: the outline state followed by all
/// six filled colours, so the theme-aware tints (and the outline's
/// `inkFaint` stroke) are pinned in a single baseline per theme.
@Suite("BookmarkGlyph snapshots")
@MainActor
struct BookmarkGlyphSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the palette strip renders in the light theme")
    func paletteLight() {
        verify(theme: .vellumLight, name: "palette_light")
    }

    @Test("the palette strip renders in the dark theme")
    func paletteDark() {
        verify(theme: .vellumDark, name: "palette_dark")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        // Render at 40pt (≈1.7× the production title size) so the notch and
        // corner radii are inspectable by eye; 7 glyphs + gaps fit 420×72.
        let view = ZStack {
            theme.background
            HStack(spacing: 18) {
                BookmarkGlyph(state: .outline, size: 40)
                ForEach(BibleBookmarkColor.allCases) { color in
                    BookmarkGlyph(state: .filled(color), size: 40)
                }
            }
        }
        .frame(width: 420, height: 72)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 420, height: 72)),
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
