import Splash
import SwiftUI
import Testing
@testable import Chat

/// Tests for ``SplashHighlighter``'s palette wiring and grammar gating.
/// We assert against the `CodePalette` values directly because Splash's
/// per-token output is opaque (`Text` from a `+`-chained run); the
/// palette is the layer where Super-specific decisions live.
@Suite("SplashHighlighter")
struct SplashHighlighterTests {
    @Test("palette derives from the active SuperTheme")
    func paletteUsesThemeForeground() {
        let theme = SuperTheme.make(.light)
        let palette = CodePalette.from(theme)
        // Plain text uses the theme's code foreground so the highlighted
        // body matches the surrounding chrome — design tokens, not magic.
        #expect(palette.plain == theme.codeForeground)
        #expect(palette.call == theme.codeForeground)
        #expect(palette.property == theme.codeForeground)
    }

    @Test("token type → palette color covers every case")
    func paletteCoversEveryTokenType() {
        let palette = CodePalette.from(.make(.dark))
        // `.custom` falls through to plain — exercise it here so the
        // switch keeps an explicit branch and never drops to a stray
        // `default`.
        let cases: [TokenType] = [
            .keyword, .string, .type, .call, .number, .comment,
            .property, .dotAccess, .preprocessing, .custom("foo"),
        ]
        // No assertion beyond "doesn't crash" — the contract is that
        // every existing case is mapped (compiler enforces exhaustiveness
        // inside `color(for:)`).
        for t in cases {
            _ = palette.color(for: t)
        }
    }

    @Test("non-Swift fence falls through to plain text without throwing")
    func nonSwiftFenceFallsBackToPlain() {
        // Triple-tick fence with `python` — Splash only ships with Swift
        // grammar, so we route through `addPlainText` and still produce
        // a Text. The test just confirms the path is exercised end-to-end.
        let text = SplashHighlighter.highlight(
            "def hello():\n    print(\"hi\")\n",
            language: "python",
            palette: .from(.make(.light))
        )
        // The returned value is a SwiftUI `Text`; we can't read its
        // characters, but this confirms the function returns without
        // tripping a precondition.
        _ = text
    }

    @Test("Swift fence with nil language defaults to Swift grammar")
    func nilLanguageDefaultsToSwift() {
        let text = SplashHighlighter.highlight(
            "let x = 1\n",
            language: nil,
            palette: .from(.make(.light))
        )
        _ = text
    }
}
