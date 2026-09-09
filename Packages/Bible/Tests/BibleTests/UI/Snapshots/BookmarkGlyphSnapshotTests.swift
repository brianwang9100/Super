#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

@Suite("BookmarkGlyph snapshots", .serialized)
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
        // Enlarge the glyphs so notch/radius details remain inspectable in the palette grid.
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

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 420, height: 150)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
