/// Breaks `BibleVerse` fragments into the per-word tokens `VerseFlowLayout`
/// reflows, flagging each verse fragment's first word.
///
/// A verse straddling a paragraph or poetry boundary appears as more than one
/// fragment sharing the same `number`. Every fragment keeps an `isVerseStart`
/// anchor word (for VoiceOver), but the raised verse number is drawn once per
/// verse — only its first fragment carries `showsVerseNumber`. Callers pass
/// the `numberedEarlier` set so a later fragment knows its number is taken.
///
/// A caseless namespace, deliberately kept off the `View` layer: SwiftUI
/// infers `@MainActor` on `View`-conforming types, which would isolate this
/// pure tokenizing to the main actor and make it untestable off it. Here it
/// stays nonisolated and unit-testable.
enum VerseTokenizer {
    /// Flattens prose verses into a single wrappable run of word tokens. The
    /// first word of each verse is flagged `isVerseStart`; it also carries the
    /// raised number unless the verse number is in `numberedEarlier` — i.e. an
    /// earlier paragraph already numbered this straddling verse.
    ///
    /// `endsHere` is the set of verse numbers whose final fragment lives in
    /// *this* paragraph. The last word of each such verse is flagged
    /// `isVerseEnd` so the chapter renderer can place a trailing annotation
    /// bubble right after it. Verses with a fragment in a later paragraph
    /// don't carry the flag here.
    static func proseTokens(
        _ verses: [BibleVerse],
        numberedEarlier: Set<Int> = [],
        endsHere: Set<Int> = []
    ) -> [VerseWordToken] {
        var tokens: [VerseWordToken] = []
        for verse in verses {
            let words = Array(verse.text.split(whereSeparator: \.isWhitespace))
            for (index, word) in words.enumerated() {
                let isLastWordOfFragment = index == words.count - 1
                tokens.append(VerseWordToken(
                    verseNumber: verse.number,
                    isVerseStart: index == 0,
                    isVerseEnd: isLastWordOfFragment && endsHere.contains(verse.number),
                    showsVerseNumber: index == 0 && !numberedEarlier.contains(verse.number),
                    word: String(word),
                    verseText: verse.text
                ))
            }
        }
        return tokens
    }

    /// Splits poetry verses into lines, breaking on the `\n` marks carried in
    /// the verse text. Each line wraps independently.
    ///
    /// `isVerseStart` flags the verse's first *word*, found wherever the text
    /// actually begins — a leading line break pushes it off the opening
    /// segment, but the flag follows it so the verse keeps exactly one VoiceOver
    /// anchor. `showsVerseNumber` follows the same word but is suppressed when
    /// `numberedEarlier` already holds the verse number.
    ///
    /// `isVerseEnd` flags the verse's *last* word in this paragraph when the
    /// verse number is in `endsHere` — i.e. no later paragraph carries
    /// another fragment of the same verse. The chapter renderer uses the flag
    /// to place trailing annotation bubbles.
    static func poetryLines(
        _ verses: [BibleVerse],
        numberedEarlier: Set<Int> = [],
        endsHere: Set<Int> = []
    ) -> [[VerseWordToken]] {
        var lines: [[VerseWordToken]] = [[]]
        // Track the index of each verse's last token across lines so we can
        // back-patch the `isVerseEnd` flag once the whole verse is laid out.
        var lastTokenLocation: [Int: (lineIndex: Int, tokenIndex: Int)] = [:]
        for verse in verses {
            var seenFirstWord = false
            let segments = verse.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (segmentIndex, segment) in segments.enumerated() {
                if segmentIndex > 0 { lines.append([]) }
                for word in segment.split(whereSeparator: \.isWhitespace) {
                    let isVerseStart = !seenFirstWord
                    let lineIndex = lines.count - 1
                    lines[lineIndex].append(VerseWordToken(
                        verseNumber: verse.number,
                        isVerseStart: isVerseStart,
                        isVerseEnd: false,
                        showsVerseNumber: isVerseStart && !numberedEarlier.contains(verse.number),
                        word: String(word),
                        verseText: verse.text
                    ))
                    lastTokenLocation[verse.number] = (lineIndex, lines[lineIndex].count - 1)
                    seenFirstWord = true
                }
            }
        }
        for verseNumber in endsHere {
            guard let location = lastTokenLocation[verseNumber] else { continue }
            let original = lines[location.lineIndex][location.tokenIndex]
            lines[location.lineIndex][location.tokenIndex] = VerseWordToken(
                verseNumber: original.verseNumber,
                isVerseStart: original.isVerseStart,
                isVerseEnd: true,
                showsVerseNumber: original.showsVerseNumber,
                word: original.word,
                verseText: original.verseText
            )
        }
        return lines.filter { !$0.isEmpty }
    }

    /// For each paragraph in reading order, the verse numbers an earlier
    /// paragraph already drew a raised number for — a verse straddling a
    /// paragraph break numbers only its first fragment. The result is parallel
    /// to `paragraphs`; element `i` is the set to pass as `numberedEarlier`
    /// when tokenizing paragraph `i`.
    static func priorlyNumberedVerses(_ paragraphs: [BibleParagraph]) -> [Set<Int>] {
        var result: [Set<Int>] = []
        var seen: Set<Int> = []
        for paragraph in paragraphs {
            result.append(seen)
            switch paragraph {
            case .heading:
                break
            case .prose(let verses), .poetry(let verses):
                seen.formUnion(verses.map(\.number))
            }
        }
        return result
    }

    /// For each paragraph in reading order, the verse numbers whose final
    /// fragment lives in *this* paragraph (i.e. no later paragraph carries
    /// another fragment of that verse). The result is parallel to
    /// `paragraphs`; element `i` is the set to pass as `endsHere` when
    /// tokenizing paragraph `i`.
    ///
    /// Used by the chapter renderer to anchor trailing annotation bubbles to
    /// the exact word a verse range ends on — overlapping verse-annotation
    /// ranges sharing a `verseEnd` then naturally stack side-by-side after
    /// that word, per the spec's multi-row semantics.
    static func verseEndsByParagraph(_ paragraphs: [BibleParagraph]) -> [Set<Int>] {
        var lastSeenIndex: [Int: Int] = [:]
        for (index, paragraph) in paragraphs.enumerated() {
            switch paragraph {
            case .heading:
                continue
            case .prose(let verses), .poetry(let verses):
                for verse in verses { lastSeenIndex[verse.number] = index }
            }
        }
        var result: [Set<Int>] = Array(repeating: [], count: paragraphs.count)
        for (verseNumber, paragraphIndex) in lastSeenIndex {
            result[paragraphIndex].insert(verseNumber)
        }
        return result
    }
}

/// One layout unit of a verse: a single word, tagged with its verse number,
/// whether it is the verse fragment's first word, and whether it draws the
/// raised verse number.
struct VerseWordToken: Sendable, Equatable {
    let verseNumber: Int
    /// The verse fragment's first word — it stands in for the whole fragment
    /// as that fragment's single VoiceOver element.
    let isVerseStart: Bool
    /// The very last word of the verse — its final fragment's last word. Only
    /// true when the verse number is in the tokenizer's `endsHere` set, so a
    /// verse straddling a paragraph break carries the flag once, at the close
    /// of its trailing fragment. Used by the chapter renderer to anchor
    /// trailing annotation bubbles.
    let isVerseEnd: Bool
    /// The word that carries the raised verse number. True only for the first
    /// fragment of a verse: a verse straddling a paragraph break is numbered
    /// once, so later fragments leave this `false`.
    let showsVerseNumber: Bool
    let word: String
    /// The verse fragment's full reading text. Carried on every word but only
    /// read by the first — it lets that word stand in for the whole verse as
    /// a single VoiceOver element.
    let verseText: String
}
