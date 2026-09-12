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
                    for frame in fragment.frames {
                        if let highlight = highlights[fragment.verseNumber] {
                            context.fill(Path(frame), with: .color(highlight.verseTint(forDarkPage: theme.isDark).color))
                        }
                        if selectedVerses.contains(fragment.verseNumber) {
                            context.fill(Path(frame), with: .color(theme.ink.opacity(0.10)))
                        }
                        if narratingVerse == fragment.verseNumber {
                            let underline = CGRect(x: frame.minX, y: frame.maxY - 1, width: frame.width, height: 1)
                            context.fill(Path(underline), with: .color(theme.ink))
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
            ForEach(fragments) { fragment in
                BiblePageVerseTarget(fragment: fragment, isSelected: selectedVerses.contains(fragment.verseNumber),
                                     highlight: highlights[fragment.verseNumber], onTap: { onTapVerse(fragment.verseNumber) })
            }
            ForEach(document.trailers.indices, id: \.self) { index in
                let trailer = document.trailers[index]
                if let line = page.lines.first(where: { $0.range.contains(trailer.range.location) }) {
                    let rect = document.rect(for: trailer.range, on: line)
                    trailerButton(trailer)
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
