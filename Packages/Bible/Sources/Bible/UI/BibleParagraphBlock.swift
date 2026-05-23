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
    /// Verse currently being spoken by the narrator — its words render
    /// with an underline so the reader can follow along. `nil` when
    /// narration is idle.
    let currentNarratingVerse: Int?
    /// Invoked with a verse number when any of its words is tapped.
    let onTapVerse: (Int) -> Void
    @Environment(\.superTheme) private var theme

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
                VerseTokenizer.proseTokens(verses, numberedEarlier: numberedEarlier),
                isPoetry: false
            )
        case .poetry(let verses):
            VStack(alignment: .leading, spacing: 5) {
                let lines = VerseTokenizer.poetryLines(verses, numberedEarlier: numberedEarlier)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    flow(line, isPoetry: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)
        }
    }

    private func flow(_ tokens: [VerseWordToken], isPoetry: Bool) -> some View {
        VerseFlowLayout {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                VerseWord(
                    token: token,
                    isSelected: selectedVerses.contains(token.verseNumber),
                    highlightColor: highlightedVerses[token.verseNumber],
                    isNarrating: currentNarratingVerse == token.verseNumber,
                    isPoetry: isPoetry,
                    theme: theme,
                    onTap: onTapVerse
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let word = styledText
            .padding(.vertical, 1.5)
            .background(wordBackground)
            .contentShape(Rectangle())
            .onTapGesture { onTap(token.verseNumber) }
        let identified = token.isVerseStart
            // Tag every verse's first word with its anchor so
            // `BibleChapterReader.body`'s `ScrollViewReader` proxy can
            // scroll directly to it as narration advances.
            ? AnyView(word.id(VerseAnchor(verseNumber: token.verseNumber)))
            : AnyView(word)
        if token.isVerseStart {
            // The verse's first word stands in for the whole verse as a
            // single VoiceOver element reading the full text.
            identified
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
            identified.accessibilityHidden(true)
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

    /// Pale-warm wash behind a selected verse — lightened text in light and
    /// sepia, a muted warm tint in dark so it reads against the dark page.
    private var selectionTint: Color {
        theme.id == .dark
            ? OKLCH(0.46, 0.07, 92, alpha: 0.55).color
            : OKLCH(0.90, 0.10, 92, alpha: 0.85).color
    }
}
