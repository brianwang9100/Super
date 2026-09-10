/// Each paragraph fragment retains a VoiceOver anchor; only the first fragment
/// shows the verse number. Pass earlier-numbered verses to avoid duplicate labels.
enum VerseTokenizer {
    /// `numberedEarlier` suppresses labels already drawn in earlier paragraphs.
    /// `endsHere` marks final fragments so annotation bubbles follow the verse's last word.
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

    /// Poetry lines wrap independently. Leading newlines do not consume the first-word
    /// VoiceOver anchor. Numbering and final-fragment flags follow proseTokens' contract.
    static func poetryLines(
        _ verses: [BibleVerse],
        numberedEarlier: Set<Int> = [],
        endsHere: Set<Int> = []
    ) -> [[VerseWordToken]] {
        var lines: [[VerseWordToken]] = [[]]
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

    /// Returns sets parallel to paragraphs for the numberedEarlier argument.
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

    /// Returns sets parallel to paragraphs for endsHere, anchoring bubbles after the final fragment.
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

struct VerseWordToken: Sendable, Equatable {
    let verseNumber: Int
    /// First word of this fragment; its sole VoiceOver element.
    let isVerseStart: Bool
    /// Last word of the final fragment, used to anchor trailing annotation bubbles.
    let isVerseEnd: Bool
    /// Only the first fragment draws the verse number.
    let showsVerseNumber: Bool
    let word: String
    /// Full fragment text, carried by all words but announced only by the first.
    let verseText: String
}
