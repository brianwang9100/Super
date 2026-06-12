import MarkdownUI
import SwiftUI

/// Bridges `SuperTheme` (Super's palette) into MarkdownUI's `Theme` so the
/// assistant text, lists, blockquotes, tables, inline code, and fenced
/// code blocks all paint against the same tokens used by the rest of the
/// chat surface.
///
/// The `codeBlock` slot is overridden entirely with ``CodeBlock``;
/// MarkdownUI's `codeSyntaxHighlighter` modifier therefore goes unused —
/// our chrome controls both the surface and the token coloring.
extension SuperTheme {
    /// Build a MarkdownUI `Theme` painted against this `SuperTheme`.
    /// `@MainActor` because every block/text closure ends up applying
    /// SwiftUI view modifiers (`markdownMargin`, `markdownTextStyle`,
    /// `relativeLineSpacing`) that are themselves MainActor-isolated.
    ///
    /// `bodyStyle` controls the `.text` slot — `.thinking` and `.banner`
    /// paint in `inkSoft` at 15pt, nil paints the default `ink` at 17pt.
    /// Baking the style into the theme (rather than layering it via
    /// `markdownTextStyle(\.text)`) keeps every text attribute resolved
    /// in one place through MarkdownUI's text composition.
    ///
    /// Body size scales by `metrics.fontScale`; headings (`.em(...)`)
    /// auto-scale because em resolves against the body. Paragraph
    /// line-spacing comes from `metrics.paragraphLineSpacingEm` and
    /// inter-paragraph margin from `metrics.paragraphSpacing` — both
    /// derived from the scale inside `MarkdownBodyMetrics`. Per-row
    /// vertical padding lives outside this theme on the hosting views
    /// themselves.
    /// Internal on purpose: ``MarkdownText`` is the sanctioned cross-module
    /// entry point (it owns caching, autoclose, and linkify). The return
    /// type is `MarkdownUI.Theme`, which consumers outside Core couldn't
    /// even name without re-adding the swift-markdown-ui dependency this
    /// move centralizes.
    @MainActor
    func markdownTheme(
        bodyStyle: MarkdownText.BodyStyle? = nil,
        metrics: MarkdownBodyMetrics = .default,
        readingFamily: String? = nil
    ) -> MarkdownUI.Theme {
        let theme = self
        // The body reading face. In the serif identity `readingFamily` is
        // "EB Garamond" (a registered family), so `FontStyle(.italic)` /
        // `FontWeight(.semibold)` below resolve to the true Italic / SemiBold
        // members rather than synthesizing a slant or bold. In the system
        // identity it's nil → the system default family (no visual change from
        // before this PR). Applied to body prose and headings; inline + fenced
        // code keep their monospaced family.
        let bodyFamily: FontFamily = readingFamily
            .map { FontFamily(.custom($0)) } ?? FontFamily(.system(.default))
        // The .text slot is built up-front per body style, then chained
        // into the rest of the theme — result-builder branching inside a
        // single `.text { ... }` historically failed to propagate
        // `FontStyle(.italic)`, and keeping the per-style builders avoids
        // re-tripping that class of MarkdownUI composition bug.
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
                // Inline code sits ~2pt below the body so dense mono spans
                // (`LazyVStack`, `scrollTo(edge:)`) don't crowd the line.
                // 0.775 em ≈ 14.7pt against the 19pt reading body.
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
                // Match the gap *between* items to the intra-paragraph line
                // spacing (in points) so the list reads with one uniform
                // rhythm and scales with the slider — a fixed 2pt bunched the
                // bullets together while their own wrapped lines breathed.
                configuration.label
                    .markdownMargin(top: metrics.paragraphLineSpacingPoints)
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
                CodeBlock(
                    language: configuration.language,
                    code: configuration.content,
                    superTheme: theme
                )
                .markdownMargin(top: 8, bottom: 8)
            }
    }
}
