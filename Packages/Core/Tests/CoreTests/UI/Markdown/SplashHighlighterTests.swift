import Splash
import SwiftUI
import Testing
@testable import Core

@Suite("SplashHighlighter")
struct SplashHighlighterTests {
    @Test("palette derives from the active SuperTheme")
    func paletteUsesThemeForeground() {
        let theme = SuperTheme.make(.vellumLight)
        let palette = CodePalette.from(theme)
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
