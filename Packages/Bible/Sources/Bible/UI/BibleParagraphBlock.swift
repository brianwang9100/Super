import Core
import SwiftUI

struct BibleParagraphBlock: View {
    let paragraph: BibleParagraph
    let selectedVerses: Set<Int>
    let highlightedVerses: [Int: BibleHighlightColor]
    /// Suppress verse numbers already drawn in earlier paragraph fragments.
    let numberedEarlier: Set<Int>
    /// Only final fragments anchor trailing glyphs.
    let verseEndsHere: Set<Int>
    /// Deduplicated ranges keyed by their final verse.
    let annotationsByVerseEnd: [Int: [BibleAnnotationTargetSpec]]
    /// Deduplicated note ranges keyed by final verse; rendered after annotation bubbles.
    let notesByVerseEnd: [Int: [BibleNoteTargetSpec]]
    let currentNarratingVerse: Int?
    let onTapVerse: (Int) -> Void
    /// Nil renders a decorative bubble without a tap action.
    let onAnnotationBubbleTap: ((BibleAnnotationTargetSpec) -> Void)?
    /// Nil renders a decorative note glyph without a tap action.
    let onNoteGlyphTap: ((BibleNoteTargetSpec) -> Void)?
    var onVisibleVerses: ((Set<Int>) -> Void)?
    var anchorsVerses = true
    @State private var visibleWords: [String: Int] = [:]
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.bibleReadingLayout) private var readingLayout
    @ScaledMetric(relativeTo: .body) private var scaledBodySize: CGFloat = SuperTypography.readingBodySize
    private var verseBodySize: CGFloat { scaledBodySize * readingLayout.scriptureScale }
    @ScaledMetric(relativeTo: .body) private var trailingBubbleSize: CGFloat = 18
    @ScaledMetric(relativeTo: .title2) private var headingSize: CGFloat = 22

    var body: some View {
        switch paragraph {
        case .heading(let title):
            Text(title)
                .font(typography.font(size: headingSize, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
                .padding(.bottom, 2)
        case .prose(let verses):
            flow(
                VerseTokenizer.proseTokens(
                    verses,
                    numberedEarlier: numberedEarlier,
                    endsHere: verseEndsHere
                ),
                isPoetry: false
            )
        case .poetry(let verses):
            VStack(alignment: .leading, spacing: readingLineSpacing) {
                let lines = VerseTokenizer.poetryLines(
                    verses,
                    numberedEarlier: numberedEarlier,
                    endsHere: verseEndsHere
                )
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    flow(line, isPoetry: true, lineID: index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)
        }
    }

    private var readingLineSpacing: CGFloat {
        BibleReadingMetrics.lineSpacing(bodySize: verseBodySize, fontScale: typography.fontScale)
    }

    private func flow(_ tokens: [VerseWordToken], isPoetry: Bool, lineID: Int = 0) -> some View {
        // Flatten words and trailers into sibling layout cells. Grouping them would break
        // independent wrapping and word tap targets.
        let items = flowItems(tokens)
        return VerseFlowLayout(lineSpacing: readingLineSpacing) {
            ForEach(items.indices, id: \.self) { index in
                if let onVisibleVerses, case .word(let token) = items[index] {
                    flowCell(items[index], isPoetry: isPoetry)
                        .onScrollVisibilityChange(threshold: 0.5) { visible in
                            visibleWords["\(lineID):\(index)"] = visible ? token.verseNumber : nil
                            onVisibleVerses(Set(visibleWords.values))
                        }
                } else {
                    flowCell(items[index], isPoetry: isPoetry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func flowCell(_ item: FlowItem, isPoetry: Bool) -> some View {
        switch item {
        case .word(let token):
            VerseWord(
                token: token,
                isSelected: selectedVerses.contains(token.verseNumber),
                highlightColor: highlightedVerses[token.verseNumber],
                isNarrating: currentNarratingVerse == token.verseNumber,
                isPoetry: isPoetry,
                anchorsVerses: anchorsVerses,
                theme: theme,
                onTap: onTapVerse
            )
        case .bubble(let spec):
            // Glyphs have no text baseline; center them within the row.
            trailingBubble(for: spec)
                .layoutValue(key: CentersInRowKey.self, value: true)
        case .note(let spec):
            trailingNoteGlyph(for: spec)
                .layoutValue(key: CentersInRowKey.self, value: true)
        }
    }

    private func flowItems(_ tokens: [VerseWordToken]) -> [FlowItem] {
        Self.flowItems(
            tokens,
            annotationsByVerseEnd: annotationsByVerseEnd,
            notesByVerseEnd: notesByVerseEnd
        )
    }

    /// Interleaves each verse-end word with its annotation bubbles, then note glyphs.
    static func flowItems(
        _ tokens: [VerseWordToken],
        annotationsByVerseEnd: [Int: [BibleAnnotationTargetSpec]],
        notesByVerseEnd: [Int: [BibleNoteTargetSpec]]
    ) -> [FlowItem] {
        var items: [FlowItem] = []
        for token in tokens {
            items.append(.word(token))
            guard token.isVerseEnd else { continue }
            if let bubbles = annotationsByVerseEnd[token.verseNumber] {
                for spec in bubbles {
                    items.append(.bubble(spec))
                }
            }
            if let notes = notesByVerseEnd[token.verseNumber] {
                for spec in notes {
                    items.append(.note(spec))
                }
            }
        }
        return items
    }

    enum FlowItem: Equatable {
        case word(VerseWordToken)
        case bubble(BibleAnnotationTargetSpec)
        case note(BibleNoteTargetSpec)
    }

    @ViewBuilder
    private func trailingBubble(for spec: BibleAnnotationTargetSpec) -> some View {
        if let onAnnotationBubbleTap {
            Button {
                onAnnotationBubbleTap(spec)
            } label: {
                AnnotationBubble(state: .filled, size: trailingBubbleSize)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.trailingBubbleLabel(for: spec))
        } else {
            AnnotationBubble(state: .filled, size: trailingBubbleSize)
                .padding(.horizontal, 3)
        }
    }

    static func trailingBubbleLabel(for spec: BibleAnnotationTargetSpec) -> String {
        switch spec {
        case .verseRange(_, _, let start, let end) where start == end:
            return "View annotation for verse \(start)"
        case .verseRange(_, _, let start, let end):
            return "View annotation for verses \(start)–\(end)"
        case .chapter:
            return "View chapter annotation"
        case .book:
            return "View book annotation"
        }
    }

    @ViewBuilder
    private func trailingNoteGlyph(for spec: BibleNoteTargetSpec) -> some View {
        if let onNoteGlyphTap {
            Button {
                onNoteGlyphTap(spec)
            } label: {
                NoteGlyph(state: .filled, size: trailingBubbleSize)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.trailingNoteGlyphLabel(for: spec))
        } else {
            NoteGlyph(state: .filled, size: trailingBubbleSize)
                .padding(.horizontal, 3)
        }
    }

    static func trailingNoteGlyphLabel(for spec: BibleNoteTargetSpec) -> String {
        switch spec {
        case .verseRange(_, _, let start, let end) where start == end:
            return "View notes for verse \(start)"
        case .verseRange(_, _, let start, let end):
            return "View notes for verses \(start)–\(end)"
        case .chapter:
            return "View chapter notes"
        case .book:
            return "View book notes"
        }
    }
}

private struct VerseWord: View {
    let token: VerseWordToken
    let isSelected: Bool
    let highlightColor: BibleHighlightColor?
    let isNarrating: Bool
    let isPoetry: Bool
    let anchorsVerses: Bool
    let theme: SuperTheme
    let onTap: (Int) -> Void
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bibleReadingLayout) private var readingLayout
    @ScaledMetric(relativeTo: .body) private var scaledBodySize: CGFloat = SuperTypography.readingBodySize
    private var verseBodySize: CGFloat { scaledBodySize * readingLayout.scriptureScale }
    @ScaledMetric(relativeTo: .caption2) private var scaledNumberSize: CGFloat = 11
    private var verseNumberSize: CGFloat { scaledNumberSize * readingLayout.scriptureScale }

    private var decorationStyle: BibleVerseDecorationStyle {
        .init(bodySize: verseBodySize * typography.fontScale, isSelected: isSelected, isNarrating: isNarrating)
    }

    var body: some View {
        if token.isVerseStart {
            // One VoiceOver element per verse fragment, announced at its first word.
            identifiedWord
                .modifier(BibleVerseAccessibility(verseNumber: token.verseNumber, verseText: token.verseText,
                                                   highlight: highlightColor, isSelected: isSelected,
                                                   onTap: { onTap(token.verseNumber) }))
        } else {
            identifiedWord.accessibilityHidden(true)
        }
    }

    // Keep concrete view identity so narration updates can diff words without rebuilding the chapter.
    @ViewBuilder
    private var identifiedWord: some View {
        let baselineDrop = decorationStyle.baselineDrop
        let word = styledText
            // Raised verse markers inflate cell boxes. Baseline-relative alignment prevents
            // fractional font scales from dipping the rule beneath numbered cells.
            .alignmentGuide(.bottom) { $0[.firstTextBaseline] + baselineDrop }
            // Use the same baseline-relative guide for a uniform wash across inflated marker cells.
            .background(alignment: .bottom) { wordHighlightBand }
            .overlay(alignment: .bottom) { underlineRule }
            .padding(.vertical, 1.5)
            .contentShape(Rectangle())
            .onTapGesture { onTap(token.verseNumber) }
            // Query updates arrive outside the caller's animation transaction. Animate only
            // highlight color here; Reduce Motion disables the fade.
            .animation(
                BibleHighlightWashMotion(reduceMotion: reduceMotion).animation,
                value: highlightColor
            )
        if token.isVerseStart && anchorsVerses {
            word.id(VerseAnchor(verseNumber: token.verseNumber))
        } else {
            word
        }
    }

    // Keep the band present with clear fill so apply/clear animates color instead of
    // inserting/removing a view. Trailing spaces join adjacent bands into one wash.
    private var wordHighlightBand: some View {
        Rectangle()
            .fill(highlightColor.map { $0.verseTint(forDarkPage: theme.isDark).color } ?? Color.clear)
            .frame(height: decorationStyle.highlightBandHeight)
    }

    // Include trailing space so adjacent word cells' washes and rules meet.
    private var styledText: Text {
        // ScaledMetric already applies Dynamic Type; relativeTo nil avoids applying it twice.
        // Accessors add the app slider and select the true italic face for poetry.
        let wordFont = typography.reading(verseBodySize, relativeTo: nil)
        let poetryFont = typography.display(verseBodySize, relativeTo: nil)
        var word = AttributedString(token.word + " ")
        word.font = isPoetry ? poetryFont : wordFont
        word.foregroundColor = theme.ink
        guard token.showsVerseNumber else { return Text(word) }
        // Scale the marker lift with both size axes, retaining the 4pt-per-11pt ratio.
        let markerOffset = verseNumberSize * typography.fontScale * (4.0 / 11.0)
        let number = BibleVerseNumber(number: token.verseNumber)
            .attributedText(
                color: theme.inkFaint,
                font: typography.font(size: verseNumberSize),
                baselineOffset: markerOffset
            )
        return Text(number + AttributedString(" ") + word)
    }

    // Text.underline skips trailing spaces. A full-cell rule joins across words;
    // solid selection takes precedence over softer dashed narration.
    @ViewBuilder
    private var underlineRule: some View {
        let style = decorationStyle
        let weight = style.underlineWeight
        if style.underline == .selection {
            Rectangle()
                .fill(theme.accent)
                .frame(height: weight)
        } else if style.underline == .narration {
            HorizontalRule()
                .stroke(
                    theme.accent.opacity(style.underlineOpacity),
                    style: style.strokeStyle
                )
                .frame(height: weight)
        }
    }


}

private struct HorizontalRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
