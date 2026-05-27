import Core
import Foundation

/// Pure helper that scans a markdown string for Bible verse citations
/// in the system-prompt's canonical notation and wraps each one in a
/// `super://bible/verse?...` markdown link. The result feeds straight
/// into MarkdownUI inside ``MarkdownText``, which renders the wrappers
/// as tappable elements; SwiftUI's `OpenURLAction` then routes the tap
/// to the Bible applet via the event bus.
///
/// Grammar handled in v1:
///
/// - **Anchor.** A canonical book name from ``Core/BibleBookIndex`` —
///   full spelling, case-sensitive — followed by whitespace and either
///   `<chapter>`, `<chapter>:<verse>`, or `<chapter>:<verse>-<verse>`.
///   Multi-word books (`1 Corinthians`, `Song of Solomon`) are matched
///   longest-first so they win over their shorter substrings (`John`,
///   `Songs`).
/// - **Continuation.** Inside the same sentence, a `,` or `;` followed
///   by `<chapter>:<verse>(-<verse>)?` inherits the prior book — so
///   `Romans 8:1; 12:1-2` linkifies the trailing `12:1-2` as Romans
///   12:1-2. The colon is required: bare `, 5` continuations are too
///   ambiguous (chapter 5? verse 5?) to autolinkify safely.
/// - **Sentence reset.** `.`, `!`, `?` followed by whitespace or
///   end-of-string clears the inherited book, as does a `\n\n`
///   paragraph break. A fresh book name also overrides the inherited
///   one, so `Romans 8:1, Hebrews 1:1` links both as their own anchors
///   without trying to inherit Romans into Hebrews.
///
/// Skip regions: fenced code blocks (``` ``` `…` ``` ```), inline code
/// (`` `…` ``), and existing markdown links (`[text](url)`) are copied
/// to the output verbatim — never substituted into and never scanned
/// for references that would double-linkify or break syntax.
///
/// Validation: a parsed chapter must lie in `1...book.chapterCount` —
/// citations like `Genesis 51:1` (Genesis has 50 chapters) are left as
/// plain text rather than producing dead links. Verse numbers are
/// sanity-bounded to `> 0` but not range-checked against per-chapter
/// totals (that data lives in the bundled Bible JSON, which Chat can't
/// import).
///
/// The function is `O(n)`-ish in input length; the per-position book
/// match is filtered by a first-character bitmap so the spelling loop
/// only runs at positions where a citation could plausibly start.
public enum BibleReferenceLinkifier {
    /// Wrap every detected verse citation in `markdown` as a markdown
    /// link to the Bible applet. Non-citation prose is preserved
    /// byte-for-byte. Safe to call on every render — there's no state
    /// outside the input string.
    public static func linkify(_ markdown: String) -> String {
        if markdown.isEmpty { return markdown }
        // Cheapest bail-outs first: no book name spelling appears at
        // all, or no digit appears at all. Either rules out every
        // possible citation.
        if !markdown.contains(where: { $0.isNumber }) { return markdown }
        if !Self.containsAnyBookSpelling(markdown) { return markdown }

        let chars = Array(markdown)
        var output = String()
        output.reserveCapacity(chars.count + 64)

        var i = 0
        var currentBook: BibleBookEntry? = nil
        while i < chars.count {
            // Fenced code block — copy verbatim through the closing fence.
            if Self.startsWithFence(chars, at: i) {
                let end = Self.findFenceEnd(chars, openerStart: i)
                output.append(contentsOf: chars[i..<end])
                i = end
                currentBook = nil
                continue
            }
            // Inline code span — copy verbatim through the closing backtick
            // (or to end-of-line if unclosed; the autocloser handles that
            // earlier in the streaming path).
            if chars[i] == "`" {
                let end = Self.findInlineCodeEnd(chars, openerStart: i)
                output.append(contentsOf: chars[i..<end])
                i = end
                continue
            }
            // Existing markdown link — `[text](url)` — copied verbatim so
            // we never double-linkify or break a hand-authored link.
            if chars[i] == "[", let end = Self.findMarkdownLinkEnd(chars, openerStart: i) {
                output.append(contentsOf: chars[i..<end])
                i = end
                continue
            }

            // Sentence boundary resets inherited book context.
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

            // Anchor — book name + chapter[:verse[-verse]] at a word
            // boundary. Validated against the book's max chapter; failure
            // falls through to a one-character advance.
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

            // Continuation — only valid when we're inside a sentence
            // following a successful anchor in the same book.
            if let book = currentBook, ch == "," || ch == ";",
               let match = Self.matchContinuation(chars, at: i, book: book) {
                // Connector punctuation + whitespace before the verse
                // span are preserved verbatim — only the digit span gets
                // wrapped, so the surface text "Romans 8:1; 12:1-2"
                // becomes "[Romans 8:1](url); [12:1-2](url)" with the
                // semicolon and space outside both links.
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

    /// A successful anchor match: the resolved book entry, the parsed
    /// chapter/verse coordinates, and the input index just past the
    /// matched text.
    private struct AnchorMatch {
        let entry: BibleBookEntry
        let chapter: Int
        let verseStart: Int?
        let verseEnd: Int?
        let endIndex: Int
    }

    /// Try to match `<bookName> <chapter>[:<verse>[-<verse>]]` starting
    /// at `start`. Returns `nil` if no spelling matches there, if the
    /// chapter isn't followed by whitespace separating it from the
    /// book, if the chapter is out of range, or if the matched span
    /// runs into an alphanumeric trailer (e.g. `Genesis 1abc`).
    private static func matchAnchor(_ chars: [Character], at start: Int) -> AnchorMatch? {
        // First-char filter rules out positions where no book name
        // could start, avoiding the full spelling loop on every
        // character.
        guard Self.bookFirstChars.contains(chars[start]) else { return nil }

        for (spelling, entry) in BibleBookIndex.spellingsLongestFirst {
            guard Self.matches(chars, at: start, prefix: spelling) else { continue }
            let afterName = start + spelling.count
            // Require a single inline space between the book name and
            // the chapter digit. Newlines and tabs would mean the user
            // wrote a multi-line citation, which we don't support.
            guard afterName < chars.count, chars[afterName] == " " else { continue }
            let chapterStart = afterName + 1
            guard let parsed = Self.parseChapterAndVerses(chars, at: chapterStart) else { continue }
            // Chapter must be in range. Verses aren't range-checked
            // per chapter — see the file-level doc.
            guard parsed.chapter > 0, parsed.chapter <= entry.chapterCount else { continue }
            // Reject alphanumeric trailers so `Genesis 1abc` doesn't
            // produce a half-link to Genesis 1.
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

    /// A successful continuation match: the verse coordinates relative
    /// to the inherited book, plus the input indices marking the verse
    /// span (which gets linkified) and the end of the whole match
    /// (which advances the cursor past the trailing whitespace).
    private struct ContinuationMatch {
        let chapter: Int
        let verseStartNumber: Int
        let verseEnd: Int?
        /// Index of the first character of the verse span — the
        /// chapter digit. Punctuation and whitespace before this stay
        /// outside the emitted link.
        let verseStart: Int
        let endIndex: Int
    }

    /// Try to match `[,;]<ws>+<chapter>:<verseStart>[-<verseEnd>]`
    /// starting at the connector punctuation. Returns `nil` if the
    /// connector isn't followed by whitespace, the verse part is
    /// missing the required colon, or the chapter is out of range for
    /// the inherited book.
    private static func matchContinuation(_ chars: [Character], at start: Int, book: BibleBookEntry) -> ContinuationMatch? {
        // Eat the connector and following inline whitespace. Multiple
        // spaces are fine ("Romans 8:1,  12:1") — what we don't accept
        // is a newline between them, which would mean the LLM is on a
        // separate line of prose where continuations stop making sense.
        var p = start + 1
        var sawSpace = false
        while p < chars.count, chars[p] == " " {
            sawSpace = true
            p += 1
        }
        guard sawSpace else { return nil }
        guard let parsed = Self.parseChapterAndVerses(chars, at: p) else { return nil }
        // Continuations REQUIRE a colon — bare-chapter continuations
        // are too ambiguous (verse 5? chapter 5?) to safely linkify.
        guard let verseStartNumber = parsed.verseStart else { return nil }
        // Same chapter-range guard as for anchors.
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

    /// Greedily parse `<digits>(:<digits>(-<digits>)?)?` starting at
    /// `start`. Returns `nil` if no digits are present. Trailing
    /// fragments — like a bare `:` with no digits after — leave the
    /// parser in a chapter-only state and don't consume the orphan
    /// punctuation, so it's emitted as literal text by the outer walk.
    private static func parseChapterAndVerses(_ chars: [Character], at start: Int) -> ParsedReference? {
        guard let (chapter, afterChapter) = Self.parseDigits(chars, from: start) else { return nil }
        // Optional `:verse(-verse)?`
        guard afterChapter < chars.count, chars[afterChapter] == ":" else {
            return ParsedReference(chapter: chapter, verseStart: nil, verseEnd: nil, endIndex: afterChapter)
        }
        let afterColon = afterChapter + 1
        guard let (verseStart, afterVerseStart) = Self.parseDigits(chars, from: afterColon) else {
            // Bare colon with no digits — treat as chapter-only and
            // back off so the `:` lands in the outer literal output.
            return ParsedReference(chapter: chapter, verseStart: nil, verseEnd: nil, endIndex: afterChapter)
        }
        guard verseStart > 0 else { return nil }
        // Optional `-verse`
        guard afterVerseStart < chars.count, chars[afterVerseStart] == "-" else {
            return ParsedReference(chapter: chapter, verseStart: verseStart, verseEnd: nil, endIndex: afterVerseStart)
        }
        let afterDash = afterVerseStart + 1
        guard let (verseEnd, afterVerseEnd) = Self.parseDigits(chars, from: afterDash) else {
            // Bare dash with no digits after — keep the single-verse
            // result and let the dash drop into the outer output.
            return ParsedReference(chapter: chapter, verseStart: verseStart, verseEnd: nil, endIndex: afterVerseStart)
        }
        // Inverted (`5-3`) or zero-bounded ranges are invalid; reject
        // the whole match.
        guard verseEnd > 0, verseEnd >= verseStart else { return nil }
        let endVerse: Int? = (verseEnd == verseStart) ? nil : verseEnd
        return ParsedReference(chapter: chapter, verseStart: verseStart, verseEnd: endVerse, endIndex: afterVerseEnd)
    }

    /// Greedy decimal-integer parse. Returns `(value, indexJustPastDigits)`
    /// or `nil` if `from` doesn't sit on a digit. Bound to non-negative
    /// because the only call sites already constrain to positive.
    private static func parseDigits(_ chars: [Character], from start: Int) -> (Int, Int)? {
        var p = start
        var value = 0
        var any = false
        while p < chars.count, let digit = chars[p].wholeNumberValue, (0...9).contains(digit) {
            value = value * 10 + digit
            p += 1
            any = true
            // Cap to a sensible bound. The largest legitimate verse
            // anywhere is Psalm 119 with 176 verses, so anything beyond
            // five digits is almost certainly user input we shouldn't
            // try to parse.
            if value > 99999 { return nil }
        }
        return any ? (value, p) : nil
    }

    // MARK: - Skip-region helpers

    /// True iff `start` is the leading backtick of a fenced opener — at
    /// least three backticks, optionally preceded only by whitespace on
    /// the line.
    private static func startsWithFence(_ chars: [Character], at start: Int) -> Bool {
        guard start + 2 < chars.count else { return false }
        guard chars[start] == "`", chars[start + 1] == "`", chars[start + 2] == "`" else { return false }
        // The fence must be the first non-whitespace on its line for
        // CommonMark to treat it as a fence. Walk backward to the line
        // start to confirm.
        var p = start
        while p > 0, chars[p - 1] != "\n" {
            if !chars[p - 1].isWhitespace { return false }
            p -= 1
        }
        return true
    }

    /// Index just past the closing ``` ``` ``` (or end-of-input if the
    /// fence is unclosed — the streaming autocloser already inserted
    /// one in the partial case, so this only handles the malformed
    /// rest case).
    private static func findFenceEnd(_ chars: [Character], openerStart: Int) -> Int {
        // Find the end-of-line for the opener, then scan forward for a
        // closing fence at the start of a subsequent line.
        var p = openerStart + 3
        while p < chars.count, chars[p] != "\n" { p += 1 }
        while p < chars.count {
            // Past a newline now — scan inline whitespace, then look
            // for three backticks.
            if chars[p] == "\n" { p += 1 }
            var q = p
            while q < chars.count, chars[q] == " " || chars[q] == "\t" { q += 1 }
            if q + 2 < chars.count,
               chars[q] == "`", chars[q + 1] == "`", chars[q + 2] == "`" {
                // Advance past the closing line.
                p = q + 3
                while p < chars.count, chars[p] != "\n" { p += 1 }
                if p < chars.count { p += 1 } // include the trailing newline
                return p
            }
            // Skip to next newline.
            while p < chars.count, chars[p] != "\n" { p += 1 }
        }
        return chars.count
    }

    /// Index just past the closing backtick of an inline code span, or
    /// end-of-input if unclosed. Inline code spans don't cross newlines
    /// per CommonMark, so we stop scanning at one.
    private static func findInlineCodeEnd(_ chars: [Character], openerStart: Int) -> Int {
        var p = openerStart + 1
        while p < chars.count, chars[p] != "`" {
            if chars[p] == "\n" { return p + 1 }
            p += 1
        }
        return p < chars.count ? p + 1 : chars.count
    }

    /// Index just past a markdown link of any common shape — inline
    /// (`[text](url)`), reference (`[text][ref]`), collapsed reference
    /// (`[text][]`), or shortcut reference (`[ref]` alone, with no
    /// following `(`/`[`) — when `openerStart` sits on the opening `[`.
    /// Returns `nil` if the `[` doesn't begin any of those, so the
    /// caller emits the literal `[` and keeps walking.
    ///
    /// Recognising reference-style shapes here is load-bearing: without
    /// it, `[Romans 8:1][ref]` would have its inner `Romans 8:1`
    /// linkified to a `super://` URL, producing nested-bracket garbage
    /// (CommonMark forbids nested links). The plain `[ref]` shortcut
    /// shape is included for the same reason — `[Genesis 1:1]` on its
    /// own would otherwise be scanned for the verse inside the brackets.
    private static func findMarkdownLinkEnd(_ chars: [Character], openerStart: Int) -> Int? {
        // Find the matching `]` (no nesting in CommonMark inline links).
        var p = openerStart + 1
        while p < chars.count, chars[p] != "]" {
            if chars[p] == "\n" { return nil }
            p += 1
        }
        guard p < chars.count, chars[p] == "]" else { return nil }
        let closeBracket = p
        p += 1
        // Possible next characters that mean "this `[…]` opens a link":
        //   `(`  → inline link `[text](url)`
        //   `[`  → reference link `[text][ref]` or collapsed `[text][]`
        // Anything else → shortcut reference `[ref]` (label only).
        if p >= chars.count || (chars[p] != "(" && chars[p] != "[") {
            // Shortcut reference label: skip the whole `[…]`. Leaves the
            // bracketed run intact in the output rather than scanning
            // inside it for verses.
            return closeBracket + 1
        }
        if chars[p] == "[" {
            // Reference or collapsed-reference link: scan to the
            // matching `]` of the label/ref bracket.
            p += 1
            while p < chars.count, chars[p] != "]" {
                if chars[p] == "\n" { return nil }
                p += 1
            }
            guard p < chars.count, chars[p] == "]" else { return nil }
            return p + 1
        }
        // Inline link — `chars[p] == "("`. Scan for the matching `)`,
        // allowing nested parens once per CommonMark; the linkifier
        // produces URLs without parens, so a single-level scan is
        // enough for our outputs and a fair approximation for
        // hand-written links.
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

    /// True iff `i` is the start of a token — i.e. character at `i - 1`
    /// (if any) is non-alphanumeric. Keeps `John` inside `Bohn 3:16`
    /// from matching even though the spelling would match the suffix.
    private static func isWordStartBoundary(_ chars: [Character], at i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = chars[i - 1]
        return !(prev.isLetter || prev.isNumber)
    }

    /// `chars[start..<start+prefix.count] == prefix`, with bounds and
    /// per-character equality. Cheaper than constructing a substring.
    private static func matches(_ chars: [Character], at start: Int, prefix: String) -> Bool {
        let prefixChars = Array(prefix)
        if start + prefixChars.count > chars.count { return false }
        for (offset, p) in prefixChars.enumerated() {
            if chars[start + offset] != p { return false }
        }
        return true
    }

    /// Wrap `text` in a markdown link with `url` as the destination.
    /// The text is included verbatim — book names and digit spans
    /// don't contain markdown metacharacters, so no escaping is
    /// required.
    private static func markdownLink(text: String, url: URL) -> String {
        "[\(text)](\(url.absoluteString))"
    }

    /// Set of every first character a book spelling could start with,
    /// used as a cheap pre-filter at each input position before we
    /// loop over the full spellings table.
    private static let bookFirstChars: Set<Character> = {
        var set: Set<Character> = []
        for (spelling, _) in BibleBookIndex.spellingsLongestFirst {
            if let first = spelling.first { set.insert(first) }
        }
        return set
    }()

    /// One-shot substring containment check that bails out as soon as
    /// any book name appears anywhere in the input. Lets the linkifier
    /// short-circuit on the dominant case (most assistant messages
    /// contain no scripture references at all).
    private static func containsAnyBookSpelling(_ haystack: String) -> Bool {
        // `String.contains(_:)` is implemented over UnsafeBufferPointer
        // comparison and is faster than building a regex alternation.
        for (spelling, _) in BibleBookIndex.spellingsLongestFirst where haystack.contains(spelling) {
            return true
        }
        return false
    }
}
