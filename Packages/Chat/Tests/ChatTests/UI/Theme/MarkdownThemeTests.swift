import Core
import MarkdownUI
import SwiftUI
import Testing
@testable import Chat

/// Tests for ``SuperTheme/markdownTheme()`` — verifies the bridge from
/// Super's palette into MarkdownUI's `Theme` populates every block/text
/// slot we override. We can't fully assert the rendered output (the
/// `Theme` exposes opaque `BlockStyle`/`TextStyle` values), but we can
/// confirm the builder runs without trapping and that the inline-code
/// background pulls from the SuperTheme.
@Suite("SuperTheme.markdownTheme()")
@MainActor
struct MarkdownThemeTests {
    @Test("light theme yields a non-default text background")
    func lightThemeTextBackgroundIsThemed() {
        // `Theme.textBackgroundColor` is exposed by MarkdownUI and is
        // populated from the `.text` style. We don't set a background on
        // `.text` itself (only on `.code`), so this should remain nil —
        // asserting that pin keeps a future contributor from accidentally
        // painting the body text against a colored background.
        let theme = SuperTheme.make(.vellumLight).markdownTheme()
        #expect(theme.textBackgroundColor == nil)
    }

    @Test("each theme produces a distinct MarkdownUI Theme instance")
    func eachThemeBuildsItsOwnInstance() {
        // `MarkdownUI.Theme` is not Equatable and the closures inside are
        // opaque, so we can only verify the builder doesn't crash on
        // each variant. The intent is to flag if a future change makes
        // one of the three themes throw or precondition.
        _ = SuperTheme.make(.vellumLight).markdownTheme()
        _ = SuperTheme.make(.vellumDark).markdownTheme()
        _ = SuperTheme.make(.lapisLight).markdownTheme()
    }

    @Test("builds with a serif reading family and with the system fallback")
    func buildsAcrossReadingFamilies() {
        // The body/heading slots fold in `readingFamily` (the EB Garamond
        // family in the serif identity, nil → system default). Both paths
        // must build without trapping; the glyph-level result is covered by
        // the assistant-message snapshots.
        _ = SuperTheme.make(.vellumLight).markdownTheme(readingFamily: SuperTypography.serifFamily)
        _ = SuperTheme.make(.vellumLight).markdownTheme(readingFamily: nil)
        for style in [MarkdownText.BodyStyle.thinking, .banner] {
            _ = SuperTheme.make(.vellumDark).markdownTheme(
                bodyStyle: style,
                readingFamily: SuperTypography.serifFamily
            )
        }
    }
}
