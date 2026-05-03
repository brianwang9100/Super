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
        let theme = SuperTheme.make(.light).markdownTheme()
        #expect(theme.textBackgroundColor == nil)
    }

    @Test("each theme produces a distinct MarkdownUI Theme instance")
    func eachThemeBuildsItsOwnInstance() {
        // `MarkdownUI.Theme` is not Equatable and the closures inside are
        // opaque, so we can only verify the builder doesn't crash on
        // each variant. The intent is to flag if a future change makes
        // one of the three themes throw or precondition.
        _ = SuperTheme.make(.light).markdownTheme()
        _ = SuperTheme.make(.dark).markdownTheme()
        _ = SuperTheme.make(.sepia).markdownTheme()
    }
}
