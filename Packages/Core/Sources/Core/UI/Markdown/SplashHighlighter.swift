import Splash
import SwiftUI

enum SplashHighlighter {
    enum Token: Equatable {
        case typed(text: String, type: TokenType)
        case plain(String)
        case whitespace(String)
    }

    static func highlight(
        _ code: String,
        language: String?,
        palette: CodePalette
    ) -> Text {
        render(tokens: tokenize(code, language: language), palette: palette)
    }

    /// Nil/swift uses the Swift grammar; other languages return one plain run.
    static func tokenize(_ code: String, language: String?) -> [Token] {
        let format = RecordingOutputFormat()
        if useSwiftGrammar(language) {
            let highlighter = SyntaxHighlighter(format: format, grammar: SwiftGrammar())
            return highlighter.highlight(code)
        }
        var builder = format.makeBuilder()
        builder.addPlainText(code)
        return builder.build()
    }

    // Build one AttributedString to avoid the growing Text + Text chain.
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
                // Leave whitespace color inherited to avoid visible leading/trailing seams.
                attributed.append(AttributedString(ws))
            }
        }
        return Text(attributed)
    }

    // Untagged snippets default to Swift, the dominant language in these chats.
    static func useSwiftGrammar(_ language: String?) -> Bool {
        guard let language else { return true }
        return language.lowercased() == "swift"
    }
}

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
        // New Splash token kinds must still render as plain text.
        @unknown default:    return plain
        }
    }
}

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
