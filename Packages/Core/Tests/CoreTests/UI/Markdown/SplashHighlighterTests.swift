import Splash
import SwiftUI
import Testing
@testable import Core

/// Tests for ``SplashHighlighter``'s palette wiring, grammar gating, and
/// the tokenize → render split. The tokenization step returns a value-
/// typed `[Token]` so we can assert on the actual stream rather than on
/// the opaque `Text` the renderer produces.
@Suite("SplashHighlighter")
struct SplashHighlighterTests {
    @Test("palette derives from the active SuperTheme")
    func paletteUsesThemeForeground() {
        let theme = SuperTheme.make(.vellumLight)
        let palette = CodePalette.from(theme)
        // Plain text uses the theme's code foreground so the highlighted
        // body matches the surrounding chrome — design tokens, not magic.
        #expect(palette.plain == theme.codeForeground)
        #expect(palette.call == theme.codeForeground)
        #expect(palette.property == theme.codeForeground)
    }

    @Test("token type → palette color: every case maps to its dedicated slot")
    func paletteCoversEveryTokenType() {
        let palette = CodePalette.from(.make(.vellumDark))
        #expect(palette.color(for: .keyword)       == palette.keyword)
        #expect(palette.color(for: .string)        == palette.string)
        #expect(palette.color(for: .type)          == palette.type)
        #expect(palette.color(for: .call)          == palette.call)
        #expect(palette.color(for: .number)        == palette.number)
        #expect(palette.color(for: .comment)       == palette.comment)
        #expect(palette.color(for: .property)      == palette.property)
        #expect(palette.color(for: .dotAccess)     == palette.dotAccess)
        #expect(palette.color(for: .preprocessing) == palette.preprocessing)
        // `.custom` falls through to plain — exercised explicitly so the
        // switch never quietly drops to a stray `default`.
        #expect(palette.color(for: .custom("foo")) == palette.plain)
    }

    @Test("non-Swift fence emits a single .plain token covering the whole body")
    func nonSwiftFenceProducesPlain() {
        let code = "def hello():\n    print(\"hi\")\n"
        let tokens = SplashHighlighter.tokenize(code, language: "python")
        #expect(tokens == [.plain(code)])
    }

    @Test("nil language defaults to Swift grammar — keywords + numbers classified")
    func nilLanguageDefaultsToSwift() {
        let tokens = SplashHighlighter.tokenize("let x = 1\n", language: nil)
        // Pull out the typed-classified tokens; Swift's grammar must
        // recognize `let` as a keyword and `1` as a number.
        let typed: [(String, TokenType)] = tokens.compactMap { token in
            if case .typed(let text, let type) = token { return (text, type) }
            return nil
        }
        #expect(typed.contains { $0.0 == "let" && $0.1 == .keyword })
        #expect(typed.contains { $0.0 == "1" && $0.1 == .number })
    }

    @Test("explicit swift language tag also routes through Swift grammar")
    func swiftLanguageTagRoutesToSwiftGrammar() {
        let tokens = SplashHighlighter.tokenize("func f() {}\n", language: "swift")
        let hasFuncKeyword = tokens.contains { token in
            if case .typed(let text, let type) = token { return text == "func" && type == .keyword }
            return false
        }
        #expect(hasFuncKeyword)
    }

    @Test("useSwiftGrammar gating: nil + swift true; everything else false")
    func useSwiftGrammarGating() {
        #expect(SplashHighlighter.useSwiftGrammar(nil))
        #expect(SplashHighlighter.useSwiftGrammar("swift"))
        #expect(SplashHighlighter.useSwiftGrammar("Swift"))
        #expect(!SplashHighlighter.useSwiftGrammar("python"))
        #expect(!SplashHighlighter.useSwiftGrammar(""))
    }
}
