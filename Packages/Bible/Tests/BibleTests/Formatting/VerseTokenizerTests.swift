import Testing
@testable import Bible

/// Tests for `VerseTokenizer` — specifically that every rendered verse keeps
/// exactly one `isVerseStart` word, the anchor VoiceOver focuses and the spot
/// the raised number is drawn.
@Suite("VerseTokenizer")
struct VerseTokenizerTests {
    @Test("each prose verse flags exactly its first word as the verse start")
    func proseVerseStarts() {
        let tokens = VerseTokenizer.proseTokens([
            BibleVerse(number: 1, text: "In the beginning"),
            BibleVerse(number: 2, text: "And the earth was formless"),
        ])
        let starts = tokens.filter(\.isVerseStart)
        #expect(starts.map(\.verseNumber) == [1, 2])
        #expect(starts.map(\.word) == ["In", "And"])
    }

    @Test("each poetry verse flags exactly one verse-start word")
    func poetryVerseStarts() {
        let tokens = VerseTokenizer.poetryLines([
            BibleVerse(number: 1, text: "Praise him\nall his angels"),
            BibleVerse(number: 2, text: "Praise him\nsun and moon"),
        ]).flatMap { $0 }
        let starts = tokens.filter(\.isVerseStart)
        #expect(starts.map(\.verseNumber) == [1, 2])
    }

    @Test("a poetry verse whose text opens with a line break keeps a reachable start")
    func poetryVerseStartingWithLineBreak() {
        let tokens = VerseTokenizer.poetryLines([
            BibleVerse(number: 7, text: "\nThe heavens declare the glory"),
        ]).flatMap { $0 }
        let starts = tokens.filter(\.isVerseStart)
        #expect(starts.count == 1, "the verse must keep exactly one VoiceOver anchor")
        #expect(starts.first?.word == "The")
    }

    @Test("every verse across a mixed poetry stanza keeps exactly one start")
    func everyPoetryVerseHasOneStart() {
        let tokens = VerseTokenizer.poetryLines([
            BibleVerse(number: 1, text: "line one\nline two"),
            BibleVerse(number: 2, text: "\nstarts after a break"),
            BibleVerse(number: 3, text: "plain"),
        ]).flatMap { $0 }
        for verseNumber in [1, 2, 3] {
            let starts = tokens.filter { $0.verseNumber == verseNumber && $0.isVerseStart }
            #expect(starts.count == 1, "verse \(verseNumber) needs exactly one anchor")
        }
    }

    @Test("every token carries its verse's full text for the VoiceOver label")
    func tokensCarryVerseText() {
        let tokens = VerseTokenizer.proseTokens([
            BibleVerse(number: 9, text: "But you are a chosen race"),
        ])
        #expect(tokens.allSatisfy { $0.verseText == "But you are a chosen race" })
    }
}
