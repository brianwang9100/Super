import Core
import SwiftUI

/// Renders one `BibleParagraph`: a section heading, a prose paragraph, or a
/// poetry stanza.
///
/// Prose and poetry lay each word out as its own tappable subview reflowed by
/// `VerseFlowLayout`, so a tap toggles the word's verse into the selection.
/// A word carries a wash behind it when its verse is selected (the transient
/// selection tint) or persistently highlighted; selection wins when a verse
/// is both. Poetry is italic, indented, and keeps the `\n` line breaks
/// carried in its verse text.
struct BibleParagraphBlock: View {
    let paragraph: BibleParagraph
    /// Verse numbers currently selected — their words render with the
    /// transient selection tint.
    let selectedVerses: Set<Int>
    /// Persisted highlight colour per verse number — their words render with
    /// that colour's wash unless the verse is also selected.
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
    /// Verse currently being spoken by the narrator — its words render
    /// with an underline so the reader can follow along. `nil` when
    /// narration is idle.
    let currentNarratingVerse: Int?
    /// Invoked with a verse number when any of its words is tapped.
    let onTapVerse: (Int) -> Void
    /// Invoked when an annotation bubble after a verse-end word is tapped.
    /// `nil` disables the bubble (used by previews / driver views without a
    /// sheet host).
    let onAnnotationBubbleTap: ((BibleAnnotationTargetSpec) -> Void)?
    @Environment(\.superTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var trailingBubbleSize: CGFloat = 16

    var body: some View {
        switch paragraph {
        case .heading(let title):
            Text(title)
                .font(.system(.title2, design: .serif))
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
            VStack(alignment: .leading, spacing: 5) {
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

    private func flow(_ tokens: [VerseWordToken], isPoetry: Bool) -> some View {
        // Interleave verse words with trailing annotation bubbles as a flat
        // list of `FlowItem`s, then `ForEach` over the items so each one is
        // a single subview to `VerseFlowLayout`. Wrapping in `Group` would
        // collapse a word + bubble into one layout cell, breaking per-word
        // tap targets and line-wrap; this projection keeps every item as
        // its own placement candidate.
        let items = flowItems(tokens)
        return VerseFlowLayout {
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
            trailingBubble(for: spec)
        }
    }

    /// Builds the flat sequence of layout items for one verse run: each
    /// word followed by any trailing annotation bubbles for that verse's
    /// end. Pure so a unit test can lock in the interleave order without
    /// standing up a SwiftUI host.
    private func flowItems(_ tokens: [VerseWordToken]) -> [FlowItem] {
        var items: [FlowItem] = []
        for token in tokens {
            items.append(.word(token))
            if token.isVerseEnd, let bubbles = annotationsByVerseEnd[token.verseNumber] {
                for spec in bubbles {
                    items.append(.bubble(spec))
                }
            }
        }
        return items
    }

    /// One flow cell: either a word or a trailing bubble. Both are siblings
    /// in `VerseFlowLayout`'s subview list.
    private enum FlowItem {
        case word(VerseWordToken)
        case bubble(BibleAnnotationTargetSpec)
    }

    @ViewBuilder
    private func trailingBubble(for spec: BibleAnnotationTargetSpec) -> some View {
        if let onAnnotationBubbleTap {
            Button {
                onAnnotationBubbleTap(spec)
            } label: {
                AnnotationBubble(state: .filled, size: trailingBubbleSize)
                    .padding(.horizontal, 2)
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
                .padding(.horizontal, 2)
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
}

/// A single tappable word of a verse — the smallest unit `VerseFlowLayout`
/// reflows. A tap reports the word's verse number; a selected or highlighted
/// verse tints the word, the trailing space included so adjacent words read
/// as one continuous wash.
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
        let word = styledText
            .padding(.vertical, 1.5)
            .background(wordBackground)
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

    /// The wash behind the word: the selection tint when selected, otherwise
    /// the persisted highlight colour, otherwise nothing. Selection wins so
    /// the reader can see which verses a pending action will act on even when
    /// they are already highlighted.
    private var wordBackground: Color {
        if isSelected { return selectionTint }
        if let highlightColor {
            return highlightColor.verseTint(forDarkPage: theme.id == .dark).color
        }
        return .clear
    }

    /// The word `Text`, prefixed with the raised verse marker on the word that
    /// carries the verse number — a verse straddling a paragraph break draws it
    /// once. A trailing space is baked in so the selection background bridges
    /// the gap to the next word.
    ///
    /// The narrator underline is applied here (not as a `.underline(...)`
    /// modifier on the outer view) so the line runs through the verse
    /// number ornament as well as the word — making it visually clear
    /// the whole verse is the unit being read.
    private var styledText: Text {
        var word = Text(token.word + " ")
            .font(isPoetry ? .body.italic() : .body)
            .foregroundStyle(theme.ink)
        if isNarrating {
            word = word.underline(true, color: theme.accent.opacity(0.65))
        }
        guard token.showsVerseNumber else { return word }
        let number = BibleVerseNumber(number: token.verseNumber)
            .text(color: theme.inkFaint)
        return number + Text(" ") + word
    }

    /// A subtle wash behind a selected verse, tinted toward the active theme's
    /// accent hue so a selection feels native to the reading theme (green on
    /// Light/Dark, warm on Sepia) and tracks the Settings accent-hue slider.
    /// The low chroma keeps it clearly a *selection* wash — distinct from the
    /// vivid highlight swatches in the action sheet — and never a highlight.
    /// Selection still wins over a persisted highlight in `wordBackground`.
    private var selectionTint: Color {
        theme.id == .dark
            ? OKLCH(0.58, 0.055, theme.accentHue, alpha: 0.43).color
            : OKLCH(0.90, 0.060, theme.accentHue, alpha: 0.82).color
    }
}
