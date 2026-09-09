import Foundation

/// Links canonical case-sensitive book names followed by one space and chapter[:verse[-verse]].
/// Longest names win. Comma/semicolon continuations require spaces and chapter:verse;
/// bare numbers are ambiguous. Sentence/paragraph boundaries reset the inherited book.
/// Code regions and existing links stay intact. Chapters are catalog-bounded; positive
/// verse numbers lack chapter-specific validation because Core cannot read applet data.
public enum BibleReferenceLinkifier {
    /// Preserves non-citation text and carries no state between calls.
    public static func linkify(_ markdown: String) -> String {
        if markdown.isEmpty { return markdown }
        if !markdown.contains(where: { $0.isNumber }) { return markdown }
        if !Self.containsAnyBookSpelling(markdown) { return markdown }

        let chars = Array(markdown)
        var output = String()
        output.reserveCapacity(chars.count + 64)

        var i = 0
        var currentBook: BibleBookEntry? = nil
        while i < chars.count {
            if Self.startsWithFence(chars, at: i) {
                let end = Self.findFenceEnd(chars, openerStart: i)
                output.append(contentsOf: chars[i..<end])
                i = end
                currentBook = nil
                continue
            }
            if chars[i] == "`" {
                let end = Self.findInlineCodeEnd(chars, openerStart: i)
                output.append(contentsOf: chars[i..<end])
                i = end
                continue
            }
            if chars[i] == "[", let end = Self.findMarkdownLinkEnd(chars, openerStart: i) {
                output.append(contentsOf: chars[i..<end])
                i = end
                continue
            }

            let ch = chars[i]
            if ch == "." || ch == "!" || ch == "?" {
                let next = i + 1
                if next == chars.count || chars[next].isWhitespace {
                    output.append(ch)
                    i += 1
                    currentBook = nil
                    continue
                }
            }
            if ch == "\n", i + 1 < chars.count, chars[i + 1] == "\n" {
                output.append(ch)
                i += 1
                currentBook = nil
                continue
            }

            if Self.isWordStartBoundary(chars, at: i),
               let match = Self.matchAnchor(chars, at: i) {
                let text = String(chars[i..<match.endIndex])
                let link = BibleDeepLink(
                    bookId: match.entry.id,
                    chapter: match.chapter,
                    verseStart: match.verseStart,
                    verseEnd: match.verseEnd
                )
                output.append(Self.markdownLink(text: text, url: link.url))
                currentBook = match.entry
                i = match.endIndex
                continue
            }

            if let book = currentBook, ch == "," || ch == ";",
               let match = Self.matchContinuation(chars, at: i, book: book) {
                // Keep connector punctuation outside the continuation's link.
                output.append(contentsOf: chars[i..<match.verseStart])
                let text = String(chars[match.verseStart..<match.endIndex])
                let link = BibleDeepLink(
                    bookId: book.id,
                    chapter: match.chapter,
                    verseStart: match.verseStartNumber,
                    verseEnd: match.verseEnd
                )
                output.append(Self.markdownLink(text: text, url: link.url))
                i = match.endIndex
                continue
            }

            output.append(ch)
            i += 1
        }

        return output
    }

    // MARK: - Anchor matching

    private struct AnchorMatch {
        let entry: BibleBookEntry
        let chapter: Int
        let verseStart: Int?
        let verseEnd: Int?
        let endIndex: Int
    }

    private static func matchAnchor(_ chars: [Character], at start: Int) -> AnchorMatch? {
        // Avoid checking every book spelling at positions that cannot start a name.
        guard Self.bookFirstChars.contains(chars[start]) else { return nil }

        for (spelling, entry) in BibleBookIndex.spellingsLongestFirst {
            guard Self.matches(chars, at: start, prefix: spelling) else { continue }
            let afterName = start + spelling.count
            guard afterName < chars.count, chars[afterName] == " " else { continue }
            let chapterStart = afterName + 1
            guard let parsed = Self.parseChapterAndVerses(chars, at: chapterStart) else { continue }
            guard parsed.chapter > 0, parsed.chapter <= entry.chapterCount else { continue }
            // Avoid half-links for alphanumeric suffixes such as Genesis 1abc.
            if parsed.endIndex < chars.count, chars[parsed.endIndex].isLetter || chars[parsed.endIndex].isNumber {
                continue
            }
            return AnchorMatch(
                entry: entry,
                chapter: parsed.chapter,
                verseStart: parsed.verseStart,
                verseEnd: parsed.verseEnd,
                endIndex: parsed.endIndex
            )
        }
        return nil
    }

    // MARK: - Continuation matching

    private struct ContinuationMatch {
        let chapter: Int
        let verseStartNumber: Int
        let verseEnd: Int?
        let verseStart: Int
        let endIndex: Int
    }

    private static func matchContinuation(_ chars: [Character], at start: Int, book: BibleBookEntry) -> ContinuationMatch? {
        var p = start + 1
        var sawSpace = false
        while p < chars.count, chars[p] == " " {
            sawSpace = true
            p += 1
        }
        guard sawSpace else { return nil }
        guard let parsed = Self.parseChapterAndVerses(chars, at: p) else { return nil }
        // Bare continuation numbers are ambiguous between chapters and verses.
        guard let verseStartNumber = parsed.verseStart else { return nil }
        guard parsed.chapter > 0, parsed.chapter <= book.chapterCount else { return nil }
        if parsed.endIndex < chars.count, chars[parsed.endIndex].isLetter || chars[parsed.endIndex].isNumber {
            return nil
        }
        return ContinuationMatch(
            chapter: parsed.chapter,
            verseStartNumber: verseStartNumber,
            verseEnd: parsed.verseEnd,
            verseStart: p,
            endIndex: parsed.endIndex
        )
    }

    // MARK: - Chapter / verse parser

    private struct ParsedReference {
        let chapter: Int
        let verseStart: Int?
        let verseEnd: Int?
        let endIndex: Int
    }

    /// Unfinished colon/dash fragments stay literal after the last complete reference.
    private static func parseChapterAndVerses(_ chars: [Character], at start: Int) -> ParsedReference? {
        guard let (chapter, afterChapter) = Self.parseDigits(chars, from: start) else { return nil }
        guard afterChapter < chars.count, chars[afterChapter] == ":" else {
            return ParsedReference(chapter: chapter, verseStart: nil, verseEnd: nil, endIndex: afterChapter)
        }
        let afterColon = afterChapter + 1
        guard let (verseStart, afterVerseStart) = Self.parseDigits(chars, from: afterColon) else {
            return ParsedReference(chapter: chapter, verseStart: nil, verseEnd: nil, endIndex: afterChapter)
        }
        guard verseStart > 0 else { return nil }
        guard afterVerseStart < chars.count, chars[afterVerseStart] == "-" else {
            return ParsedReference(chapter: chapter, verseStart: verseStart, verseEnd: nil, endIndex: afterVerseStart)
        }
        let afterDash = afterVerseStart + 1
        guard let (verseEnd, afterVerseEnd) = Self.parseDigits(chars, from: afterDash) else {
            return ParsedReference(chapter: chapter, verseStart: verseStart, verseEnd: nil, endIndex: afterVerseStart)
        }
        guard verseEnd > 0, verseEnd >= verseStart else { return nil }
        let endVerse: Int? = (verseEnd == verseStart) ? nil : verseEnd
        return ParsedReference(chapter: chapter, verseStart: verseStart, verseEnd: endVerse, endIndex: afterVerseEnd)
    }

    private static func parseDigits(_ chars: [Character], from start: Int) -> (Int, Int)? {
        var p = start
        var value = 0
        var any = false
        while p < chars.count, let digit = chars[p].wholeNumberValue, (0...9).contains(digit) {
            value = value * 10 + digit
            p += 1
            any = true
            // Bound arbitrary numeric input well above valid chapters/verses.
            if value > 99999 { return nil }
        }
        return any ? (value, p) : nil
    }

    // MARK: - Skip-region helpers

    private static func startsWithFence(_ chars: [Character], at start: Int) -> Bool {
        guard start + 2 < chars.count else { return false }
        guard chars[start] == "`", chars[start + 1] == "`", chars[start + 2] == "`" else { return false }
        var p = start
        while p > 0, chars[p - 1] != "\n" {
            if !chars[p - 1].isWhitespace { return false }
            p -= 1
        }
        return true
    }

    private static func findFenceEnd(_ chars: [Character], openerStart: Int) -> Int {
        var p = openerStart + 3
        while p < chars.count, chars[p] != "\n" { p += 1 }
        while p < chars.count {
            if chars[p] == "\n" { p += 1 }
            var q = p
            while q < chars.count, chars[q] == " " || chars[q] == "\t" { q += 1 }
            if q + 2 < chars.count,
               chars[q] == "`", chars[q + 1] == "`", chars[q + 2] == "`" {
                p = q + 3
                while p < chars.count, chars[p] != "\n" { p += 1 }
                if p < chars.count { p += 1 } // include the trailing newline
                return p
            }
            while p < chars.count, chars[p] != "\n" { p += 1 }
        }
        return chars.count
    }

    // This limited inline-code scan stops at a newline even without a closing backtick.
    private static func findInlineCodeEnd(_ chars: [Character], openerStart: Int) -> Int {
        var p = openerStart + 1
        while p < chars.count, chars[p] != "`" {
            if chars[p] == "\n" { return p + 1 }
            p += 1
        }
        return p < chars.count ? p + 1 : chars.count
    }

    // Skip inline and reference/shortcut links to avoid nesting links inside their labels.
    private static func findMarkdownLinkEnd(_ chars: [Character], openerStart: Int) -> Int? {
        var p = openerStart + 1
        while p < chars.count, chars[p] != "]" {
            if chars[p] == "\n" { return nil }
            p += 1
        }
        guard p < chars.count, chars[p] == "]" else { return nil }
        let closeBracket = p
        p += 1
        if p >= chars.count || (chars[p] != "(" && chars[p] != "[") {
            return closeBracket + 1
        }
        if chars[p] == "[" {
            p += 1
            while p < chars.count, chars[p] != "]" {
                if chars[p] == "\n" { return nil }
                p += 1
            }
            guard p < chars.count, chars[p] == "]" else { return nil }
            return p + 1
        }
        // Balance destination parentheses so an existing link remains intact.
        var depth = 1
        p += 1
        while p < chars.count, depth > 0 {
            switch chars[p] {
            case "(": depth += 1
            case ")": depth -= 1
            case "\n": return nil
            default: break
            }
            p += 1
        }
        return depth == 0 ? p : nil
    }

    // MARK: - Boundaries & utilities

    private static func isWordStartBoundary(_ chars: [Character], at i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = chars[i - 1]
        return !(prev.isLetter || prev.isNumber)
    }

    private static func matches(_ chars: [Character], at start: Int, prefix: String) -> Bool {
        let prefixChars = Array(prefix)
        if start + prefixChars.count > chars.count { return false }
        for (offset, p) in prefixChars.enumerated() {
            if chars[start + offset] != p { return false }
        }
        return true
    }

    // Canonical book names and numeric spans contain no Markdown metacharacters to escape.
    private static func markdownLink(text: String, url: URL) -> String {
        "[\(text)](\(url.absoluteString))"
    }

    private static let bookFirstChars: Set<Character> = {
        var set: Set<Character> = []
        for (spelling, _) in BibleBookIndex.spellingsLongestFirst {
            if let first = spelling.first { set.insert(first) }
        }
        return set
    }()

    private static func containsAnyBookSpelling(_ haystack: String) -> Bool {
        for (spelling, _) in BibleBookIndex.spellingsLongestFirst where haystack.contains(spelling) {
            return true
        }
        return false
    }
}
