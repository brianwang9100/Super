import Core
import CoreText
import SwiftUI

struct BibleBookPage: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 18
    @Environment(\.self) private var environment
    let page: BiblePage
    let document: BiblePageDocument
    let selectedVerses: Set<Int>
    let highlights: [Int: BibleHighlightColor]
    let narratingVerse: Int?
    let onTapVerse: (Int) -> Void
    var onAnnotation: (BibleAnnotationTargetSpec) -> Void = { _ in }
    var onNote: (BibleNoteTargetSpec) -> Void = { _ in }

    var body: some View {
        let fragments = page.fragments(in: document)
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for fragment in fragments {
                    let style = BibleVerseDecorationStyle(bodySize: document.bodyFontSize,
                        isSelected: selectedVerses.contains(fragment.verseNumber),
                        isNarrating: narratingVerse == fragment.verseNumber)
                    for frame in fragment.frames {
                        guard let line = page.lines.first(where: { $0.frame.minY == frame.minY }) else { continue }
                        let bottom = line.baseline + style.baselineDrop
                        if let highlight = highlights[fragment.verseNumber] {
                            let band = CGRect(x: frame.minX, y: bottom - style.highlightBandHeight,
                                              width: frame.width, height: style.highlightBandHeight)
                            context.fill(Path(band), with: .color(highlight.verseTint(forDarkPage: theme.isDark).color))
                        }
                        switch style.underline {
                        case .selection:
                            let rule = CGRect(x: frame.minX, y: bottom - style.underlineWeight,
                                              width: frame.width, height: style.underlineWeight)
                            context.fill(Path(rule), with: .color(theme.accent))
                        case .narration:
                            var rule = Path()
                            rule.move(to: CGPoint(x: frame.minX, y: bottom - style.underlineWeight / 2))
                            rule.addLine(to: CGPoint(x: frame.maxX, y: bottom - style.underlineWeight / 2))
                            context.stroke(rule, with: .color(theme.accent.opacity(style.underlineOpacity)), style: style.strokeStyle)
                        case .none: break
                        }
                    }
                }
                context.withCGContext { graphics in
                    let color = theme.ink.resolve(in: environment)
                    graphics.setFillColor(CGColor(red: CGFloat(color.red), green: CGFloat(color.green),
                                                  blue: CGFloat(color.blue), alpha: CGFloat(color.opacity)))
                    graphics.textMatrix = .identity
                    graphics.translateBy(x: 0, y: size.height)
                    graphics.scaleBy(x: 1, y: -1)
                    let typesetter = CTTypesetterCreateWithAttributedString(document.text)
                    for line in page.lines {
                        let text = CTTypesetterCreateLine(typesetter, CFRange(location: line.range.location, length: line.range.length))
                        graphics.textPosition = CGPoint(x: line.frame.minX, y: size.height - line.baseline)
                        CTLineDraw(text, graphics)
                    }
                }
            }
            .accessibilityHidden(true)
            ForEach(page.headingFragments(in: document)) { heading in
                Color.clear
                    .frame(width: heading.frame.width, height: heading.frame.height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(heading.text)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(-Double(heading.sourceRange.location))
                    .allowsHitTesting(false)
                    .offset(x: heading.frame.minX, y: heading.frame.minY)
            }
            ForEach(fragments) { fragment in
                BiblePageVerseTarget(fragment: fragment, isSelected: selectedVerses.contains(fragment.verseNumber),
                                     highlight: highlights[fragment.verseNumber], onTap: { onTapVerse(fragment.verseNumber) })
            }
            ForEach(document.trailers.indices, id: \.self) { index in
                let trailer = document.trailers[index]
                if let line = page.lines.first(where: { $0.range.contains(trailer.range.location) }) {
                    let rect = document.rect(for: trailer.range, on: line)
                    trailerButton(trailer)
                        .accessibilitySortPriority(-Double(trailer.range.location))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func trailerButton(_ trailer: BiblePageDocument.Trailer) -> some View {
        switch trailer.kind {
        case .annotation(let spec):
            Button { onAnnotation(spec) } label: { AnnotationBubble(state: .filled, size: glyphSize * typography.fontScale) }
                .buttonStyle(.plain)
                .accessibilityLabel(BibleParagraphBlock.trailingBubbleLabel(for: spec))
        case .note(let spec):
            Button { onNote(spec) } label: { NoteGlyph(state: .filled, size: glyphSize * typography.fontScale) }
                .buttonStyle(.plain)
                .accessibilityLabel(BibleParagraphBlock.trailingNoteGlyphLabel(for: spec))
        }
    }
}
