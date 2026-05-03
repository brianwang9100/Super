import MarkdownUI
import SwiftUI

/// Bridges `SuperTheme` (Super's palette) into MarkdownUI's `Theme` so the
/// assistant text, lists, blockquotes, tables, inline code, and fenced
/// code blocks all paint against the same tokens used by the rest of the
/// chat surface.
///
/// The `codeBlock` slot is overridden entirely with ``CodeBlockView``;
/// MarkdownUI's `codeSyntaxHighlighter` modifier therefore goes unused —
/// our chrome controls both the surface and the token coloring.
extension SuperTheme {
    /// Build a MarkdownUI `Theme` painted against this `SuperTheme`.
    /// `@MainActor` because every block/text closure ends up applying
    /// SwiftUI view modifiers (`markdownMargin`, `markdownTextStyle`,
    /// `relativeLineSpacing`) that are themselves MainActor-isolated.
    ///
    /// `bodyStyle` controls the `.text` slot — `.thinking` paints in
    /// `inkSoft` at 13pt and italic, `.banner` paints `inkSoft` at 13pt,
    /// nil paints the default `ink` at 15pt. Baking the style into the
    /// theme (rather than layering it via `markdownTextStyle(\.text)`)
    /// is the only path that reliably propagates `FontStyle(.italic)`
    /// through MarkdownUI's text composition.
    ///
    /// Font sizes (15pt body, 1.6/1.35/1.15 em headings) and margins are
    /// hard-coded to match the design tokens. M12 will multiply these
    /// by the persisted `SettingRecord.fontScale` and `density` knobs;
    /// today the settings are saved but not yet read by this builder.
    @MainActor
    func markdownTheme(bodyStyle: MarkdownText.BodyStyle? = nil) -> MarkdownUI.Theme {
        let theme = self
        // Result-builder branching inside `.text { ... }` doesn't
        // propagate `FontStyle(.italic)` reliably, so the .text slot is
        // built up-front per body style, then chained into the rest of
        // the theme.
        let textStyledTheme: MarkdownUI.Theme = {
            switch bodyStyle {
            case .thinking:
                return MarkdownUI.Theme().text {
                    ForegroundColor(theme.inkSoft)
                    FontSize(13)
                    FontStyle(.italic)
                }
            case .banner:
                return MarkdownUI.Theme().text {
                    ForegroundColor(theme.inkSoft)
                    FontSize(13)
                }
            case .none:
                return MarkdownUI.Theme().text {
                    ForegroundColor(theme.ink)
                    FontSize(15)
                }
            }
        }()
        return textStyledTheme
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                ForegroundColor(theme.codeInlineForeground)
                BackgroundColor(theme.codeInlineBackground)
            }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(theme.accent) }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.6))
                        ForegroundColor(theme.ink)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.35))
                        ForegroundColor(theme.ink)
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.15))
                        ForegroundColor(theme.ink)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.18))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .blockquote { configuration in
                configuration.label
                    .padding(.leading, 12)
                    .padding(.vertical, 4)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.borderFaint)
                            .frame(width: 3)
                    }
                    .markdownTextStyle {
                        ForegroundColor(theme.inkSoft)
                        FontStyle(.italic)
                    }
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2)
            }
            .table { configuration in
                // Horizontal scroll keeps wide tables from clipping on a
                // 402pt iPhone; the rounded border matches the inline-code
                // and tool-call card surfaces.
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .padding(.vertical, 4)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.borderFaint, lineWidth: 1)
                )
                .markdownMargin(top: 6, bottom: 6)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(theme.inkSoft)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .codeBlock { configuration in
                CodeBlockView(
                    language: configuration.language,
                    code: configuration.content,
                    superTheme: theme
                )
                .markdownMargin(top: 8, bottom: 8)
            }
    }
}
