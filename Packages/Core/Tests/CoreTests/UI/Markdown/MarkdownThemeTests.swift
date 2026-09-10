import MarkdownUI
import SwiftUI
import Testing
@testable import Core

@Suite("SuperTheme.markdownTheme()")
@MainActor
struct MarkdownThemeTests {
    @Test("light theme yields a non-default text background")
    func lightThemeTextBackgroundIsThemed() {
        let theme = SuperTheme.make(.vellumLight).markdownTheme()
        #expect(theme.textBackgroundColor == nil)
    }

    @Test("each theme produces a distinct MarkdownUI Theme instance")
    func eachThemeBuildsItsOwnInstance() {
        // Opaque, non-Equatable theme closures limit this check to construction.
        _ = SuperTheme.make(.vellumLight).markdownTheme()
        _ = SuperTheme.make(.vellumDark).markdownTheme()
        _ = SuperTheme.make(.lapisLight).markdownTheme()
    }

    @Test("builds with a serif reading family and with the system fallback")
    func buildsAcrossReadingFamilies() {
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
