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
            flow(proseTokens(verses), isPoetry: false)
        case .poetry(let verses):
            VStack(alignment: .leading, spacing: 5) {
                let lines = poetryLines(verses)
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
                    isPoetry: isPoetry,
                    theme: theme,
                    onTap: onTapVerse
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Flattens prose verses into a single wrappable run of word tokens.
    private func proseTokens(_ verses: [BibleVerse]) -> [VerseWordToken] {
        var tokens: [VerseWordToken] = []
        for verse in verses {
            let words = verse.text.split(whereSeparator: \.isWhitespace)
            for (index, word) in words.enumerated() {
                tokens.append(VerseWordToken(
                    verseNumber: verse.number,
                    showsNumber: index == 0,
                    word: String(word),
                    verseText: verse.text
                ))
            }
        }
        return tokens
    }

    /// Splits poetry verses into lines, breaking on the `\n` marks carried in
    /// the verse text. Each line wraps independently.
    private func poetryLines(_ verses: [BibleVerse]) -> [[VerseWordToken]] {
        var lines: [[VerseWordToken]] = [[]]
        for verse in verses {
            let segments = verse.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (segmentIndex, segment) in segments.enumerated() {
                if segmentIndex > 0 { lines.append([]) }
                let words = segment.split(whereSeparator: \.isWhitespace)
                for (wordIndex, word) in words.enumerated() {
                    lines[lines.count - 1].append(VerseWordToken(
                        verseNumber: verse.number,
                        showsNumber: segmentIndex == 0 && wordIndex == 0,
                        word: String(word),
                        verseText: verse.text
                    ))
                }
            }
        }
        return lines.filter { !$0.isEmpty }
    }
}

/// One layout unit of a verse: a single word, tagged with its verse number
/// and whether it is the verse's first word (which carries the verse marker).
struct VerseWordToken {
    let verseNumber: Int
    let showsNumber: Bool
    let word: String
    /// The verse fragment's full reading text. Carried on every word but only
    /// read by the first — it lets that word stand in for the whole verse as
    /// a single VoiceOver element.
    let verseText: String
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
    let isPoetry: Bool
    let theme: SuperTheme
    let onTap: (Int) -> Void

    var body: some View {
        styledText
            .padding(.vertical, 1.5)
            .background(wordBackground)
            .contentShape(Rectangle())
            .onTapGesture { onTap(token.verseNumber) }
            // The verse's first word stands in for the whole verse as one
            // VoiceOver element reading the full text; every other word is
            // hidden so the verse isn't re-announced word by word.
            .accessibilityElement()
            .accessibilityHidden(!token.showsNumber)
            .accessibilityLabel(BibleVerseAnnouncement.label(
                verseNumber: token.verseNumber,
                verseText: token.verseText
            ))
            .accessibilityValue(BibleVerseAnnouncement.highlightValue(highlightColor))
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(accessibilityTraits)
            .accessibilityAction { onTap(token.verseNumber) }
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

    /// The word `Text`, prefixed with the raised verse marker when this is the
    /// verse's first word. A trailing space is baked in so the selection
    /// background bridges the gap to the next word.
    private var styledText: Text {
        let word = Text(token.word + " ")
            .font(isPoetry ? .body.italic() : .body)
            .foregroundStyle(theme.ink)
        guard token.showsNumber else { return word }
        return BibleVerseNumber(number: token.verseNumber).text(color: theme.inkFaint)
            + Text(" ")
            + word
    }

    /// Pale-warm wash behind a selected verse — lightened text in light and
    /// sepia, a muted warm tint in dark so it reads against the dark page.
    private var selectionTint: Color {
        theme.id == .dark
            ? OKLCH(0.46, 0.07, 92, alpha: 0.55).color
            : OKLCH(0.90, 0.10, 92, alpha: 0.85).color
    }
}
