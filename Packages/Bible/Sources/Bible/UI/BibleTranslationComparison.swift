import Core
import SwiftUI

/// Aligned rows inside the shared chapter reader's scroll, navigation, and study presentation.
struct BibleTranslationComparison: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    let chapter: BibleChapter
    let comparison: BibleChapterComparison
    let selectedVerses: Set<Int>
    let highlightedVerses: [Int: BibleHighlightColor]
    let annotationsByVerseEnd: [Int: [BibleAnnotationTargetSpec]]
    let notesByVerseEnd: [Int: [BibleNoteTargetSpec]]
    let currentNarratingVerse: Int?
    let onTapVerse: (Int) -> Void
    let onAnnotation: ((BibleAnnotationTargetSpec) -> Void)?
    let onNote: ((BibleNoteTargetSpec) -> Void)?
    let onRowVisibilityChange: (Int, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            translationHeader
            if let secondary = comparison.chapter {
                let content = BibleComparisonAssembler.assemble(primary: chapter, secondary: secondary)
                ForEach(content.rows) { row in
                    rowContent(row)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) { theme.ink.opacity(0.10).frame(height: 1) }
                        .id(VerseAnchor(verseNumber: row.verseNumber))
                        .onScrollVisibilityChange(threshold: 0.5) { onRowVisibilityChange(row.verseNumber, $0) }
                }
                rowLayout {
                    headings(content.primaryTrailingHeadings)
                    headings(content.secondaryTrailingHeadings)
                }
            } else {
                VStack(spacing: 12) {
                    Text(comparison.error ?? "Chapter unavailable")
                    Button("Retry", action: comparison.onRetry).frame(minHeight: 44)
                }
                .font(typography.font(.body))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
        }
    }

    private var translationHeader: some View {
        HStack(spacing: 24) {
            Text(comparison.primaryTranslation.rawValue).frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(BibleTranslation.allCases.filter { $0 != comparison.primaryTranslation }) { translation in
                    Button(translation.name) { comparison.onSelectTranslation(translation) }
                }
            } label: {
                Label(comparison.secondaryTranslation.rawValue, systemImage: "chevron.down")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("Comparison translation: \(comparison.secondaryTranslation.name)")
        }
        .font(typography.font(.headline))
        .foregroundStyle(theme.inkSoft)
        .padding(.vertical, 8)
    }

    private var rowLayout: AnyLayout {
        comparison.stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }

    private func rowContent(_ row: BibleComparisonRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !comparison.stacked, !(row.primary?.headings.isEmpty ?? true) || !(row.secondary?.headings.isEmpty ?? true) {
                HStack(alignment: .top, spacing: 24) {
                    headings(row.primary?.headings ?? [])
                    headings(row.secondary?.headings ?? [])
                }
            }
            rowLayout {
                cell(row.primary, verse: row.verseNumber, secondary: false)
                cell(row.secondary, verse: row.verseNumber, secondary: true)
            }
        }
    }

    private func cell(_ cell: BibleComparisonRow.Cell?, verse: Int, secondary: Bool) -> some View {
        let translation = secondary ? comparison.secondaryTranslation : comparison.primaryTranslation
        return VStack(alignment: .leading, spacing: 8) {
            if comparison.stacked {
                Text(translation.rawValue).font(typography.font(.caption)).foregroundStyle(theme.inkFaint)
            }
            if let cell {
                if comparison.stacked { headings(cell.headings) }
                let numberedEarlier = VerseTokenizer.priorlyNumberedVerses(cell.paragraphs)
                let verseEnds = VerseTokenizer.verseEndsByParagraph(cell.paragraphs)
                ForEach(Array(cell.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    BibleParagraphBlock(
                        paragraph: paragraph,
                        selectedVerses: secondary ? comparison.selectedVerses : selectedVerses,
                        highlightedVerses: highlightedVerses,
                        numberedEarlier: numberedEarlier[index], verseEndsHere: verseEnds[index],
                        annotationsByVerseEnd: annotationsByVerseEnd, notesByVerseEnd: notesByVerseEnd,
                        currentNarratingVerse: secondary ? comparison.currentNarratingVerse : currentNarratingVerse,
                        onTapVerse: secondary ? comparison.onTapVerse : onTapVerse,
                        onAnnotationBubbleTap: secondary ? comparison.onAnnotation : onAnnotation,
                        onNoteGlyphTap: onNote, anchorsVerses: false
                    )
                }
            } else {
                Text("Verse \(verse) is not present in \(translation.rawValue)")
                    .font(typography.font(.callout)).foregroundStyle(theme.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func headings(_ titles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                BibleParagraphBlock(paragraph: .heading(title), selectedVerses: [], highlightedVerses: [:],
                    numberedEarlier: [], verseEndsHere: [], annotationsByVerseEnd: [:], notesByVerseEnd: [:],
                    currentNarratingVerse: nil, onTapVerse: { _ in }, onAnnotationBubbleTap: nil, onNoteGlyphTap: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
