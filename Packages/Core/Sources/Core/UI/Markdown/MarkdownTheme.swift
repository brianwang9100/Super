import MarkdownUI
import SwiftUI

extension SuperTheme {
    // Keep MarkdownUI types internal; cross-module callers use MarkdownText for caching and transforms.
    @MainActor
    func markdownTheme(
        bodyStyle: MarkdownText.BodyStyle? = nil,
        metrics: MarkdownBodyMetrics = .default,
        readingFamily: String? = nil
    ) -> MarkdownUI.Theme {
        let theme = self
        // Use the family so bold/italic selects real faces; code keeps its monospaced family.
        let bodyFamily: FontFamily = readingFamily
            .map { FontFamily(.custom($0)) } ?? FontFamily(.system(.default))
        // Branching inside one text builder failed to propagate italic in MarkdownUI.
        // Build each body style separately before composing the remaining slots.
        let textStyledTheme: MarkdownUI.Theme = {
            switch bodyStyle {
            case .thinking, .banner:
                return MarkdownUI.Theme().text {
                    bodyFamily
                    ForegroundColor(theme.inkSoft)
                    FontSize(15 * metrics.fontScale)
                }
            case .none:
                return MarkdownUI.Theme().text {
                    bodyFamily
                    ForegroundColor(theme.ink)
                    FontSize(metrics.bodyFontSize)
                }
            }
        }()
        return textStyledTheme
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.775))
                ForegroundColor(theme.codeInlineForeground)
                BackgroundColor(theme.codeInlineBackground)
            }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(theme.accent) }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        bodyFamily
                        FontWeight(.semibold)
                        FontSize(.em(1.6))
                        ForegroundColor(theme.ink)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        bodyFamily
                        FontWeight(.semibold)
                        FontSize(.em(1.35))
                        ForegroundColor(theme.ink)
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        bodyFamily
                        FontWeight(.semibold)
                        FontSize(.em(1.15))
                        ForegroundColor(theme.ink)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(metrics.paragraphLineSpacingEm))
                    .markdownMargin(top: 0, bottom: metrics.paragraphSpacing)
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
                // Scale item gaps with wrapped-line spacing; fixed gaps bunch larger lists.
                configuration.label
                    .markdownMargin(top: metrics.paragraphLineSpacingPoints)
            }
            .table { configuration in
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
                CodeBlock(
                    language: configuration.language,
                    code: configuration.content,
                    superTheme: theme
                )
                .markdownMargin(top: 8, bottom: 8)
            }
    }
}
