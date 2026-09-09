import Core
import SwiftUI

struct AnnotationBlock: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    // Pair the reader's Dynamic Type base with typography's app-slider scaling.
    @ScaledMetric(relativeTo: .body) private var verseBodySize: CGFloat = SuperTypography.readingBodySize

    let title: String
    /// Nil for book/chapter targets or unavailable text; renders title and summary only.
    let verseText: String?
    let summary: String
    let provenance: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(typography.reading(22, relativeTo: .title2, weight: .semibold))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let verseText {
                verseTextBlock(verseText)
            }
            // The host supplies Markdown metrics and citation routing through bibleMarkdownRendering.
            MarkdownText(summary)
                .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.backgroundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.borderFaint, lineWidth: 0.5)
        )
    }

    private func verseTextBlock(_ text: String) -> some View {
        Text(text)
            .font(typography.reading(verseBodySize, relativeTo: nil))
            .lineSpacing(BibleReadingMetrics.lineSpacing(bodySize: verseBodySize, fontScale: typography.fontScale))
            .foregroundStyle(theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(width: 3)
            }
    }

    private var footer: some View {
        Text(provenance)
            .font(typography.font(size: 10, weight: .regular, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(theme.inkMute)
            .lineLimit(1)
            .padding(.top, 2)
    }
}
