/// Breaks `BibleVerse` fragments into the per-word tokens `VerseFlowLayout`
/// reflows, flagging each verse's first word.
///
/// A caseless namespace, deliberately kept off the `View` layer: SwiftUI
/// infers `@MainActor` on `View`-conforming types, which would isolate this
/// pure tokenizing to the main actor and make it untestable off it. Here it
/// stays nonisolated and unit-testable.
enum VerseTokenizer {
    /// Flattens prose verses into a single wrappable run of word tokens. The
    /// first word of each verse is flagged `isVerseStart`.
    static func proseTokens(_ verses: [BibleVerse]) -> [VerseWordToken] {
        var tokens: [VerseWordToken] = []
        for verse in verses {
            let words = verse.text.split(whereSeparator: \.isWhitespace)
            for (index, word) in words.enumerated() {
                tokens.append(VerseWordToken(
                    verseNumber: verse.number,
                    isVerseStart: index == 0,
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
    /// segment, but the flag follows it so the verse keeps exactly one raised
    /// number and one VoiceOver anchor.
    static func poetryLines(_ verses: [BibleVerse]) -> [[VerseWordToken]] {
        var lines: [[VerseWordToken]] = [[]]
        for verse in verses {
            var seenFirstWord = false
            let segments = verse.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (segmentIndex, segment) in segments.enumerated() {
                if segmentIndex > 0 { lines.append([]) }
                for word in segment.split(whereSeparator: \.isWhitespace) {
                    lines[lines.count - 1].append(VerseWordToken(
                        verseNumber: verse.number,
                        isVerseStart: !seenFirstWord,
                        word: String(word),
                        verseText: verse.text
                    ))
                    seenFirstWord = true
                }
            }
        }
        return lines.filter { !$0.isEmpty }
    }
}

/// One layout unit of a verse: a single word, tagged with its verse number
/// and whether it is the verse's first word.
struct VerseWordToken: Sendable {
    let verseNumber: Int
    /// The verse's first word — it carries the raised verse number and stands
    /// in for the whole verse as the verse's single VoiceOver element.
    let isVerseStart: Bool
    let word: String
    /// The verse fragment's full reading text. Carried on every word but only
    /// read by the first — it lets that word stand in for the whole verse as
    /// a single VoiceOver element.
    let verseText: String
}
