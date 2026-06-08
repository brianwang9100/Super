import Core
import SwiftUI

/// Renders one `BibleParagraph`: a section heading, a prose paragraph, or a
/// poetry stanza.
///
/// Prose and poetry lay each word out as its own tappable subview reflowed by
/// `VerseFlowLayout`, so a tap toggles the word's verse into the selection.
/// A selected verse draws a solid underline; a persistently highlighted verse
/// carries a colour wash behind it; a verse that is both shows the underline
/// over the wash. Poetry is italic, indented, and keeps the `\n` line breaks
/// carried in its verse text.
struct BibleParagraphBlock: View {
    let paragraph: BibleParagraph
    /// Verse numbers currently selected — their words render with a solid
    /// underline.
    let selectedVerses: Set<Int>
    /// Persisted highlight colour per verse number — their words render with
    /// that colour's wash, shown together with the selection underline when a
    /// verse is both highlighted and selected.
    let highlightedVerses: [Int: BibleHighlightColor]
    /// Verse numbers an earlier paragraph already drew the raised number for —
    /// a verse straddling a paragraph break is numbered once, at its first
    /// fragment, so this block leaves those numbers off.
    let numberedEarlier: Set<Int>
    /// Verse numbers whose final fragment lives in this paragraph — used to
    /// flag `isVerseEnd` on the right token so trailing annotation bubbles
    /// land at the close of the verse, even when it straddles a paragraph.
    let verseEndsHere: Set<Int>
    /// Annotation target specs keyed by `verseEnd`, each value the list of
    /// (deduplicated) ranges that end at that verse — drives the trailing
    /// bubble stack after the last word of the verse. An empty map means no
    /// verse-target annotations in this paragraph; no bubbles render.
    let annotationsByVerseEnd: [Int: [BibleAnnotationTargetSpec]]
    /// Note target specs keyed by `verseEnd`, each value the list of
    /// (deduplicated) ranges holding ≥1 note that ends at that verse —
    /// drives the trailing note glyphs, rendered *after* any annotation
    /// bubbles so the cluster reads annotation-then-note (the `VerseTrailers`
    /// order). An empty map means no verse-target notes in this paragraph.
    let notesByVerseEnd: [Int: [BibleNoteTargetSpec]]
    /// Verse currently being spoken by the narrator — its words render
    /// with a dashed underline so the reader can follow along. `nil` when
    /// narration is idle.
    let currentNarratingVerse: Int?
    /// Invoked with a verse number when any of its words is tapped.
    let onTapVerse: (Int) -> Void
    /// Invoked when an annotation bubble after a verse-end word is tapped.
    /// `nil` disables the bubble (used by previews / driver views without a
    /// sheet host).
    let onAnnotationBubbleTap: ((BibleAnnotationTargetSpec) -> Void)?
    /// Invoked when a note glyph after a verse-end word is tapped — opens the
    /// note list sheet for that range. `nil` disables the glyph (previews /
    /// driver views without a sheet host).
    let onNoteGlyphTap: ((BibleNoteTargetSpec) -> Void)?
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// Verse-body base point — matches `VerseWord.verseBodySize` so the line
    /// gap scales on the same two axes (OS Dynamic Type via the metric, the app
    /// slider via `typography.fontScale`) as the words it spaces.
    @ScaledMetric(relativeTo: .body) private var verseBodySize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var trailingBubbleSize: CGFloat = 18
    /// Section-heading base point, declared via `@ScaledMetric` so the heading
    /// composes OS Dynamic Type on top of the app font-scale `SuperTypography`
    /// folds in — the dual-axis pattern. Base 22 == `.title2` at the default
    /// content-size category, preserving the pre-migration size.
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
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    flow(line, isPoetry: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)
        }
    }

    /// Gap between wrapped prose lines and between poetry lines, scaled the
    /// same two axes as the body words it spaces — `verseBodySize` folds in OS
    /// Dynamic Type, `fontScale` folds in the app slider — so the gap grows
    /// with the text instead of staying pinned at the historical 5pt.
    private var readingLineSpacing: CGFloat {
        BibleReadingMetrics.lineSpacing(bodySize: verseBodySize, fontScale: typography.fontScale)
    }

    private func flow(_ tokens: [VerseWordToken], isPoetry: Bool) -> some View {
        // Interleave verse words with trailing annotation bubbles as a flat
        // list of `FlowItem`s, then `ForEach` over the items so each one is
        // a single subview to `VerseFlowLayout`. Wrapping in `Group` would
        // collapse a word + bubble into one layout cell, breaking per-word
        // tap targets and line-wrap; this projection keeps every item as
        // its own placement candidate.
        let items = flowItems(tokens)
        return VerseFlowLayout(lineSpacing: readingLineSpacing) {
            ForEach(items.indices, id: \.self) { index in
                flowCell(items[index], isPoetry: isPoetry)
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
                theme: theme,
                onTap: onTapVerse
            )
        case .bubble(let spec):
            // The trailing glyphs carry no verse-text baseline, so flag them to
            // centre vertically in their row rather than baseline-align with the
            // words — keeping them mid-line beside the verse text.
            trailingBubble(for: spec)
                .layoutValue(key: CentersInRowKey.self, value: true)
        case .note(let spec):
            trailingNoteGlyph(for: spec)
                .layoutValue(key: CentersInRowKey.self, value: true)
        }
    }

    /// Thin wrapper around the pure `flowItems(_:annotationsByVerseEnd:notesByVerseEnd:)`
    /// that closes over the instance's two trailing-glyph maps.
    private func flowItems(_ tokens: [VerseWordToken]) -> [FlowItem] {
        Self.flowItems(
            tokens,
            annotationsByVerseEnd: annotationsByVerseEnd,
            notesByVerseEnd: notesByVerseEnd
        )
    }

    /// Builds the flat sequence of layout items for one verse run: each word
    /// followed by any trailing glyphs for that verse's end — annotation
    /// bubbles first, then note glyphs, locking the annotation-then-note
    /// cluster order. Pure so a unit test can assert the interleave contract
    /// (word, then bubble(s), then note(s) per `isVerseEnd` token, then the
    /// next word) without standing up a SwiftUI host.
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

    /// One flow cell: a word, a trailing annotation bubble, or a trailing
    /// note glyph. All are siblings in `VerseFlowLayout`'s subview list.
    /// Internal — exposed for `BibleParagraphBlockFlowItemsTests` to assert
    /// the interleave contract; not part of any public API surface.
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
            // No tap host — render the glyph as a decoration only. Lets a
            // preview / driver view show the bubble without wiring a
            // sheet path.
            AnnotationBubble(state: .filled, size: trailingBubbleSize)
                .padding(.horizontal, 3)
        }
    }

    /// VoiceOver label for the trailing bubble. The call site only ever
    /// produces `.verseRange` specs (the chapter reader builds the
    /// annotations map under a `target == .verse` guard), but a `switch`
    /// here makes that contract explicit so a future caller that hands
    /// in a `.book` / `.chapter` spec gets a sensible label instead of
    /// "View annotation for verse 0".
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
            // No tap host — render the glyph as a decoration only, matching
            // the bubble's preview / driver fallback.
            NoteGlyph(state: .filled, size: trailingBubbleSize)
                .padding(.horizontal, 3)
        }
    }

    /// VoiceOver label for the trailing note glyph. As with the bubble, the
    /// call site only produces `.verseRange` specs; the full `switch` keeps a
    /// future `.book` / `.chapter` caller from reading "verse 0".
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

/// A single tappable word of a verse — the smallest unit `VerseFlowLayout`
/// reflows. A tap reports the word's verse number; a selected verse underlines
/// the word and a highlighted verse washes it, the trailing space included so
/// adjacent words read as one continuous span.
private struct VerseWord: View {
    let token: VerseWordToken
    let isSelected: Bool
    /// The verse's persisted highlight colour, or `nil` when not highlighted.
    let highlightColor: BibleHighlightColor?
    /// Whether the narrator is currently speaking this verse — true on
    /// every word of the verse so the underline runs through the whole
    /// span, even when the verse straddles a paragraph break.
    let isNarrating: Bool
    let isPoetry: Bool
    let theme: SuperTheme
    let onTap: (Int) -> Void
    @Environment(\.superTypography) private var typography
    /// Verse-word base point, declared via `@ScaledMetric` so reading text
    /// composes OS Dynamic Type on top of the app font-scale `SuperTypography`
    /// folds in. Base 17 == `.body`, the pre-migration size.
    @ScaledMetric(relativeTo: .body) private var verseBodySize: CGFloat = 17
    /// Raised verse-marker base point. Base 11 == `.caption2`, the
    /// pre-migration size; tracks the same two axes as the word it precedes.
    @ScaledMetric(relativeTo: .caption2) private var verseNumberSize: CGFloat = 11

    /// Distance from the text baseline down to the underline, scale-aware the
    /// same way as `markerOffset`: the rendered body point size (`verseBodySize`
    /// folds in OS Dynamic Type; `fontScale` folds in the app slider) times the
    /// body face's descent ratio. Anchoring the rule here — one constant for
    /// every word — sits it just under the glyphs as a box-bottom anchor did,
    /// but identically on each, so the marker-inflated verse-number cell no
    /// longer dips. See `identifiedWord`.
    private var underlineBaselineDrop: CGFloat {
        verseBodySize * typography.fontScale * Self.underlineDescentRatio
    }

    /// Descent-to-point-size ratio of the reading body face, used to place the
    /// underline a glyph's-descent below the baseline.
    private static let underlineDescentRatio: CGFloat = 0.22

    var body: some View {
        if token.isVerseStart {
            // The verse's first word stands in for the whole verse as a
            // single VoiceOver element reading the full text.
            identifiedWord
                .accessibilityElement()
                .accessibilityLabel(BibleVerseAnnouncement.label(
                    verseNumber: token.verseNumber,
                    verseText: token.verseText
                ))
                .accessibilityValue(BibleVerseAnnouncement.highlightValue(highlightColor))
                .accessibilityHint(accessibilityHint)
                .accessibilityAddTraits(accessibilityTraits)
                .accessibilityAction(.default) { onTap(token.verseNumber) }
        } else {
            // Every later word folds into the verse's first — hidden so the
            // verse isn't re-announced word by word.
            identifiedWord.accessibilityHidden(true)
        }
    }

    /// The tappable word, plus the verse-start `id` when this is the
    /// first word of its verse — used by `BibleChapterReader.body`'s
    /// `ScrollViewReader` proxy to scroll directly to the active
    /// verse as narration advances. Built with `@ViewBuilder` rather
    /// than `AnyView` so SwiftUI sees a concrete return type and can
    /// diff verse words across narration ticks instead of treating
    /// every cell as opaque (which forces a full rebuild of the
    /// chapter's hundreds of words on every `currentNarratingVerse`
    /// change).
    @ViewBuilder
    private var identifiedWord: some View {
        let baselineDrop = underlineBaselineDrop
        let word = styledText
            // Anchor the underline to the text baseline + a fixed descent rather
            // than the cell's own box bottom. The verse-number cell's raised
            // marker inflates its box, and at fractional font scales its box
            // bottom rounds ~2px off a plain word's — so a bottom-anchored rule
            // dipped under the verse number. Baselines *are* aligned across the
            // row (`VerseFlowLayout` aligns on `firstTextBaseline`), so making
            // `.bottom` baseline-relative keeps every word's rule on one line.
            .alignmentGuide(.bottom) { $0[.firstTextBaseline] + baselineDrop }
            // The highlight wash is bottom-anchored to that same baseline-relative
            // guide and given a constant height — for the identical reason the
            // underline is. A box-filling `.background` washed the marker-inflated
            // verse-number cell taller than its neighbors and broke the seam.
            .background(alignment: .bottom) { wordHighlightBand }
            .overlay(alignment: .bottom) { underlineRule }
            .padding(.vertical, 1.5)
            .contentShape(Rectangle())
            .onTapGesture { onTap(token.verseNumber) }
        if token.isVerseStart {
            word.id(VerseAnchor(verseNumber: token.verseNumber))
        } else {
            word
        }
    }

    /// A button always; also `.isSelected` while the verse is in the pending
    /// selection, so VoiceOver appends "Selected".
    private var accessibilityTraits: AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : .isButton
    }

    private var accessibilityHint: String {
        isSelected
            ? "Removes the verse from the selection"
            : "Selects the verse for highlight, copy, and share"
    }

    /// The wash behind the word: a fixed-height band in the persisted highlight
    /// colour, or nothing when the verse isn't highlighted. Bottom-anchored (in
    /// `identifiedWord`) to the same baseline-relative `.bottom` guide as the
    /// underline and given a constant `highlightBandHeight`, so every word's wash
    /// — verse-number cell included — is the same height. A plain `.background`
    /// fill instead tracked each cell's natural box, and the raised verse-number
    /// marker inflates that box upward, so the marker cell washed taller than its
    /// neighbors and broke the seam (worst at fractional font scales). The
    /// trailing space baked into `styledText` makes adjacent cells abut, so the
    /// bands join into one continuous wash — the same mechanism `underlineRule`
    /// relies on. Selection is a solid line *over* the wash, so a selected *and*
    /// highlighted verse shows both at once.
    @ViewBuilder
    private var wordHighlightBand: some View {
        if let highlightColor {
            Rectangle()
                .fill(highlightColor.verseTint(forDarkPage: theme.isDark).color)
                .frame(height: highlightBandHeight)
        }
    }

    /// Height of the highlight wash: the cap/ascent extent above the baseline plus
    /// `underlineBaselineDrop` below it. Both terms are scale-aware the same way as
    /// the underline metrics — `verseBodySize` folds in OS Dynamic Type, `fontScale`
    /// the app slider. Anchored at `baseline + drop` and extending upward by this
    /// height, the band's top lands a fixed distance above the baseline on *every*
    /// cell, independent of the verse-number marker's box inflation.
    private var highlightBandHeight: CGFloat {
        verseBodySize * typography.fontScale * Self.highlightAscentRatio + underlineBaselineDrop
    }

    /// Above-baseline extent of the wash as a fraction of the rendered body point
    /// size — the wash counterpart to `underlineDescentRatio`. Tuned so the band
    /// clears the glyph cap height with a little breathing room at the default
    /// reading size; below the baseline the band reuses the underline's descent.
    private static let highlightAscentRatio: CGFloat = 1.0

    /// The word `Text`, prefixed with the raised verse marker on the word that
    /// carries the verse number — a verse straddling a paragraph break draws it
    /// once. A trailing space is baked in so the word's cell — and the
    /// `underlineRule` drawn under it — extends to meet the next word.
    private var styledText: Text {
        // Verse body is the roman reading face (EB Garamond Regular under the
        // serif identity, system serif under system). Poetry uses the true
        // italic brand face (EB Garamond Italic) rather than a synthesized
        // slant. Both are sized off `verseBodySize` (already `@ScaledMetric`
        // for OS Dynamic Type) with `relativeTo: nil` so the scale isn't
        // applied twice; `fontScale` is folded in by the accessors. Verse
        // numbers stay system-sans below.
        let wordFont = typography.reading(verseBodySize, relativeTo: nil)
        let poetryFont = typography.display(verseBodySize, relativeTo: nil)
        var word = AttributedString(token.word + " ")
        word.font = isPoetry ? poetryFont : wordFont
        word.foregroundColor = theme.ink
        guard token.showsVerseNumber else { return Text(word) }
        // Raise the marker proportionally to its resolved point size so it sits
        // at a consistent superscript height across both scale axes. The
        // @ScaledMetric base folds in OS Dynamic Type; `fontScale` folds in the
        // app slider (SuperTypography applies it to the marker font the same
        // way). 4/11 keeps the historical ratio — 4pt at the 11pt base — so the
        // 1.0× / default-Dynamic-Type look is unchanged.
        let markerOffset = verseNumberSize * typography.fontScale * (4.0 / 11.0)
        let number = BibleVerseNumber(number: token.verseNumber)
            .attributedText(
                color: theme.inkFaint,
                font: typography.font(size: verseNumberSize),
                baselineOffset: markerOffset
            )
        // Marker, an unstyled separator space (inherits the body run), then the
        // word — composed as one `AttributedString` so the paragraph stays a
        // single wrapping `Text`. `AttributedString.+` replaces `Text.+`.
        return Text(number + AttributedString(" ") + word)
    }

    /// The selection / narration underline, drawn as a bottom-aligned rule
    /// rather than `Text.underline`.
    ///
    /// `Text.underline` decorates only the glyph runs and skips the trailing
    /// space that separates words, so its line broke at every word boundary.
    /// This rule spans the word's full cell — trailing space included — and the
    /// flow layout adds no inter-word gap, so each word's rule abuts the next
    /// into one continuous line. Selection is a full-strength solid line;
    /// narration is a softer dashed line so the two never look alike. Selection
    /// wins when a verse is both selected and narrated — it is the active user
    /// action.
    @ViewBuilder
    private var underlineRule: some View {
        let weight = underlineWeight
        if isSelected {
            Rectangle()
                .fill(theme.accent)
                .frame(height: weight)
        } else if isNarrating {
            HorizontalRule()
                .stroke(
                    theme.accent.opacity(0.65),
                    style: StrokeStyle(lineWidth: weight, dash: [3, 3])
                )
                .frame(height: weight)
        }
    }

    /// Weight shared by the solid (selection) and dashed (narration) rules so
    /// the two stay visually equal. It tracks the rendered body size — the
    /// `verseBodySize` @ScaledMetric folds in OS Dynamic Type, `fontScale` folds
    /// in the app slider — so the rule grows with the text it underlines: 2pt at
    /// the default reading size, thinning to 1pt only at the min slider (0.8×)
    /// and thickening further under large Dynamic Type.
    ///
    /// It's **rounded to a whole point** (and floored at 1): a whole-point value
    /// is also a whole number of device pixels at @2x (×2) and @3x (×3), so the
    /// rule lands on the pixel grid and rasterizes an identical thickness on
    /// every wrapped row. A fractional weight — e.g. the earlier 1.5pt = 4.5px
    /// at @3x, or a naive `2 × 0.8 = 1.6pt` — can't, and reads a touch thicker
    /// on some rows than others. The `round()` is what keeps it crisp.
    private var underlineWeight: CGFloat {
        max(1, (verseBodySize * typography.fontScale * Self.underlineWeightRatio).rounded())
    }

    /// Weight-to-point-size ratio, tuned so the rule rounds to 2pt at the
    /// default reading size (17pt × 1.0 × 0.10 = 1.7 → 2), 1pt at the min slider
    /// (0.8×), and up from 2pt under large Dynamic Type.
    private static let underlineWeightRatio: CGFloat = 0.10
}

/// A single horizontal line spanning its rect, centred vertically — stroked
/// dashed for the narrator's follow-along underline.
private struct HorizontalRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
