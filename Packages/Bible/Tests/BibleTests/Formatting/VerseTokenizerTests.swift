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

    @Test("a prose verse numbered earlier keeps its anchor but drops the number")
    func proseSuppressesNumberAlreadyDrawn() {
        let tokens = VerseTokenizer.proseTokens(
            [BibleVerse(number: 6, text: "Because it is contained in Scripture")],
            numberedEarlier: [6]
        )
        let start = tokens.first { $0.isVerseStart }
        #expect(start?.isVerseStart == true, "the VoiceOver anchor survives")
        #expect(start?.showsVerseNumber == false, "the raised number is not redrawn")
    }

    @Test("a poetry verse numbered earlier keeps its anchor but drops the number")
    func poetrySuppressesNumberAlreadyDrawn() {
        let tokens = VerseTokenizer.poetryLines(
            [BibleVerse(number: 6, text: "Behold, I lay in Zion\na chief cornerstone")],
            numberedEarlier: [6]
        ).flatMap { $0 }
        let start = tokens.first { $0.isVerseStart }
        #expect(start?.isVerseStart == true, "the VoiceOver anchor survives")
        #expect(start?.showsVerseNumber == false, "the raised number is not redrawn")
    }

    @Test("a verse not numbered earlier still draws its number")
    func unsuppressedVerseShowsNumber() {
        let tokens = VerseTokenizer.proseTokens(
            [BibleVerse(number: 7, text: "For you who believe")],
            numberedEarlier: [6]
        )
        #expect(tokens.first?.showsVerseNumber == true)
    }

    @Test("a poetry verse straddling line breaks within one paragraph numbers once")
    func poetryVerseAcrossLineBreaksNumbersOnce() {
        let tokens = VerseTokenizer.poetryLines([
            BibleVerse(number: 1, text: "Behold, I lay in Zion\na chief cornerstone\nchosen and precious"),
        ]).flatMap { $0 }
        let numbered = tokens.filter { $0.verseNumber == 1 && $0.showsVerseNumber }
        #expect(numbered.count == 1, "a multi-line verse draws its number on exactly one word")
    }

    @Test("priorlyNumberedVerses suppresses a verse straddling prose into poetry")
    func priorlyNumberedVersesAcrossParagraphs() {
        let sets = VerseTokenizer.priorlyNumberedVerses([
            .heading("A Living Stone"),
            .prose([BibleVerse(number: 6, text: "Because it is contained in Scripture")]),
            .poetry([BibleVerse(number: 6, text: "Behold, I lay in Zion a chief cornerstone")]),
        ])
        #expect(sets.count == 3)
        #expect(sets[0].isEmpty, "the heading sees no earlier numbers")
        #expect(sets[1].isEmpty, "the verse's first fragment numbers it")
        #expect(sets[2].contains(6), "the straddling fragment finds 6 already numbered")
    }

    @Test("priorlyNumberedVerses never suppresses a verse that appears only once")
    func priorlyNumberedVersesKeepsSingleOccurrenceVerses() {
        let sets = VerseTokenizer.priorlyNumberedVerses([
            .prose([BibleVerse(number: 1, text: "In the beginning")]),
            .prose([BibleVerse(number: 2, text: "And the earth was formless")]),
            .poetry([BibleVerse(number: 3, text: "Let there be light")]),
        ])
        #expect(sets[0].isEmpty, "the first paragraph has nothing earlier")
        #expect(sets[1] == [1], "only verse 1 was numbered before paragraph 1")
        #expect(sets[2] == [1, 2], "verse 3 is not among the numbers drawn earlier")
    }
}
