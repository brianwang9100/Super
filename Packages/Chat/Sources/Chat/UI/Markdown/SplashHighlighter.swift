import Splash
import SwiftUI

/// Splash → SwiftUI `Text` adapter. Tokenizes a snippet through Splash's
/// `SyntaxHighlighter` (Swift grammar today; other languages fall through
/// to plain monospaced text) and concatenates the resulting tokens into a
/// single `Text` painted with the active theme's code colors.
///
/// Lives outside MarkdownUI's `CodeSyntaxHighlighter` protocol because
/// our ``CodeBlockView`` overrides the entire code-block slot — the
/// chrome (lang label, copy pill, dark surface) needs more than a `Text`,
/// so the highlighter is invoked directly from there.
enum SplashHighlighter {
    /// Returns a `Text` with each Splash token painted in the matching
    /// per-token color from the supplied palette.
    ///
    /// `language` controls grammar selection. Today only `swift` (and its
    /// common aliases) maps to a real grammar; everything else degrades to
    /// `addPlainText`-only output, which still benefits from the
    /// monospaced font and code foreground color but skips token coloring.
    static func highlight(
        _ code: String,
        language: String?,
        palette: CodePalette
    ) -> Text {
        let format = TextOutputFormat(palette: palette)
        if isSwift(language) {
            let highlighter = SyntaxHighlighter(format: format, grammar: SwiftGrammar())
            return highlighter.highlight(code)
        }
        // Non-Swift fence: paint as plain code-foreground text. We still
        // route through the format so the monospaced font + foreground
        // color match the highlighted path exactly.
        var builder = format.makeBuilder()
        builder.addPlainText(code)
        return builder.build()
    }

    private static func isSwift(_ language: String?) -> Bool {
        guard let language else { return true } // bare ``` defaults to Swift
        return ["swift"].contains(language.lowercased())
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
        }
    }
}

/// Splash output format that builds a single SwiftUI `Text` by chaining
/// token-colored `Text` runs with `+`. Tokens get the palette color;
/// plain text and whitespace inherit the surrounding code foreground.
private struct TextOutputFormat: OutputFormat {
    let palette: CodePalette

    func makeBuilder() -> Builder { Builder(palette: palette) }

    struct Builder: OutputBuilder {
        let palette: CodePalette
        private var accumulated: Text = Text("")

        init(palette: CodePalette) {
            self.palette = palette
        }

        mutating func addToken(_ token: String, ofType type: TokenType) {
            accumulated = accumulated + Text(token).foregroundColor(palette.color(for: type))
        }

        mutating func addPlainText(_ text: String) {
            accumulated = accumulated + Text(text).foregroundColor(palette.plain)
        }

        mutating func addWhitespace(_ whitespace: String) {
            accumulated = accumulated + Text(whitespace)
        }

        mutating func build() -> Text { accumulated }
    }
}
