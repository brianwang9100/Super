#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BookmarkGlyph` — the ribbon glyph marking a bookmarked
/// chapter. One palette grid per theme: the top row is the `outline` state
/// followed by the six filled colours; the bottom row is the six `unassigned`
/// pale-wash states (the empty-slot rendering). All theme-aware tints — the
/// `outline`'s `inkFaint` stroke, the filled tints, and the unassigned soft
/// tints — are pinned in a single baseline per theme.
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
        // corner radii are inspectable by eye; 7 glyphs + gaps fit 420 wide.
        // Top row: outline + six filled. Bottom row: six unassigned washes.
        let view = ZStack {
            theme.background
            VStack(spacing: 18) {
                HStack(spacing: 18) {
                    BookmarkGlyph(state: .outline, size: 40)
                    ForEach(BibleBookmarkColor.allCases) { color in
                        BookmarkGlyph(state: .filled(color), size: 40)
                    }
                }
                HStack(spacing: 18) {
                    ForEach(BibleBookmarkColor.allCases) { color in
                        BookmarkGlyph(state: .unassigned(color), size: 40)
                    }
                }
            }
        }
        .frame(width: 420, height: 150)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 420, height: 150)),
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
