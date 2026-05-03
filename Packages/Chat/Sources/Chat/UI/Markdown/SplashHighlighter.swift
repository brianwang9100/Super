import Splash
import SwiftUI

/// Splash → SwiftUI `Text` adapter. Tokenizes a snippet through Splash's
/// `SyntaxHighlighter` (Swift grammar today; other languages fall through
/// to plain monospaced text) and renders the resulting tokens into a
/// single `Text` painted with the active theme's code colors.
///
/// Lives outside MarkdownUI's `CodeSyntaxHighlighter` protocol because
/// our ``CodeBlockView`` overrides the entire code-block slot — the
/// chrome (lang label, copy pill, dark surface) needs more than a `Text`,
/// so the highlighter is invoked directly from there.
///
/// The pipeline is split in two so tests can assert the *token stream*
/// without trying to introspect a `Text`:
/// 1. ``tokenize(_:language:)`` returns a value-typed `[Token]`.
/// 2. ``render(tokens:palette:)`` materializes that into a `Text` via
///    one `AttributedString` (constant-cost append, no `Text + Text`
///    chain).
enum SplashHighlighter {
    /// One unit of output from the tokenizer. Mirrors the three callbacks
    /// `Splash.OutputBuilder` exposes — typed tokens, unclassified plain
    /// runs (used for non-Swift fences), and pure whitespace (which
    /// Splash emits separately so adjacent tokens don't smear).
    enum Token: Equatable {
        case typed(text: String, type: TokenType)
        case plain(String)
        case whitespace(String)
    }

    /// Returns a `Text` with each token painted in the matching per-token
    /// color from the supplied palette.
    static func highlight(
        _ code: String,
        language: String?,
        palette: CodePalette
    ) -> Text {
        render(tokens: tokenize(code, language: language), palette: palette)
    }

    /// Pure tokenization step. Public-to-the-module so tests can assert
    /// the token stream directly. `language` controls grammar selection;
    /// today only `swift` (the only Splash grammar shipped) and a `nil`
    /// language map to a real grammar — everything else degrades to a
    /// single `.plain` run carrying the whole code body.
    static func tokenize(_ code: String, language: String?) -> [Token] {
        let format = RecordingOutputFormat()
        if useSwiftGrammar(language) {
            let highlighter = SyntaxHighlighter(format: format, grammar: SwiftGrammar())
            return highlighter.highlight(code)
        }
        // Non-Swift fence: emit a single plain run for the whole code body.
        // The renderer paints it in the code foreground so it still matches
        // the highlighted path's chrome — just without per-token coloring.
        var builder = format.makeBuilder()
        builder.addPlainText(code)
        return builder.build()
    }

    /// Materialize `[Token]` into a `Text`. Builds an `AttributedString`
    /// once and wraps it — avoids the quadratic-ish `Text + Text` chain
    /// that the original Splash builder used.
    static func render(tokens: [Token], palette: CodePalette) -> Text {
        var attributed = AttributedString()
        for token in tokens {
            switch token {
            case .typed(let text, let type):
                var run = AttributedString(text)
                run.foregroundColor = palette.color(for: type)
                attributed.append(run)
            case .plain(let text):
                var run = AttributedString(text)
                run.foregroundColor = palette.plain
                attributed.append(run)
            case .whitespace(let ws):
                // Whitespace inherits the surrounding code foreground via
                // the Text's `.font(...)` modifier on the call site — no
                // explicit color so trailing/leading runs don't introduce
                // a visible seam.
                attributed.append(AttributedString(ws))
            }
        }
        return Text(attributed)
    }

    /// Whether to route this fence through Splash's Swift grammar. Bare
    /// ` ``` ` fences default to Swift because that's the dominant
    /// language in this project's chats — the alternative ("default to
    /// plain") would silently strip highlighting from snippets the user
    /// most commonly pastes. Other tagged languages fall through to the
    /// plain-text path.
    static func useSwiftGrammar(_ language: String?) -> Bool {
        guard let language else { return true }
        return language.lowercased() == "swift"
    }
}

/// Per-token colors for the syntax highlighter. Derived from `SuperTheme`
/// so light, dark, and sepia themes all stay coherent without hard-coded
/// OKLCH triplets in the highlighter itself.
struct CodePalette: Sendable, Equatable {
    let plain: SwiftUI.Color
    let keyword: SwiftUI.Color
    let string: SwiftUI.Color
    let type: SwiftUI.Color
    let call: SwiftUI.Color
    let number: SwiftUI.Color
    let comment: SwiftUI.Color
    let property: SwiftUI.Color
    let dotAccess: SwiftUI.Color
    let preprocessing: SwiftUI.Color

    /// Default palette derived from a `SuperTheme`. Hue choices match the
    /// design's `--code-kw / --code-str / --code-num / --code-cmt` tokens
    /// in `theme.jsx` — purples for keywords, warm yellow for strings,
    /// red for numbers, muted slate for comments.
    static func from(_ theme: SuperTheme) -> CodePalette {
        CodePalette(
            plain:         theme.codeForeground,
            keyword:       OKLCH(0.78, 0.13, 300).color,
            string:        OKLCH(0.82, 0.11,  85).color,
            type:          OKLCH(0.80, 0.12, 200).color,
            call:          theme.codeForeground,
            number:        OKLCH(0.80, 0.12,  25).color,
            comment:       OKLCH(0.60, 0.02, 200).color,
            property:      theme.codeForeground,
            dotAccess:     OKLCH(0.78, 0.13, 300).color,
            preprocessing: OKLCH(0.78, 0.13, 300).color
        )
    }

    func color(for token: TokenType) -> SwiftUI.Color {
        switch token {
        case .keyword:       return keyword
        case .string:        return string
        case .type:          return type
        case .call:          return call
        case .number:        return number
        case .comment:       return comment
        case .property:      return property
        case .dotAccess:     return dotAccess
        case .preprocessing: return preprocessing
        case .custom:        return plain
        // Splash's `TokenType` isn't `@frozen`, so a future minor bump
        // can ship a new case (e.g. regex/interpolation tokens). Fall
        // back to plain rather than hard-trapping at runtime — the
        // unhighlighted text still renders in the code foreground.
        @unknown default:    return plain
        }
    }
}

/// Splash output format that records each `addToken` / `addPlainText` /
/// `addWhitespace` callback into a `[Token]`. The renderer turns this
/// list into a `Text`; tests consume the list directly so we can assert
/// "this snippet produced these tokens" without inspecting opaque `Text`.
private struct RecordingOutputFormat: OutputFormat {
    func makeBuilder() -> Builder { Builder() }

    struct Builder: OutputBuilder {
        private var tokens: [SplashHighlighter.Token] = []

        mutating func addToken(_ token: String, ofType type: TokenType) {
            tokens.append(.typed(text: token, type: type))
        }

        mutating func addPlainText(_ text: String) {
            tokens.append(.plain(text))
        }

        mutating func addWhitespace(_ whitespace: String) {
            tokens.append(.whitespace(whitespace))
        }

        mutating func build() -> [SplashHighlighter.Token] { tokens }
    }
}
