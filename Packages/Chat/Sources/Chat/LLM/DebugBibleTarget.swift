#if DEBUG
import Core
import Foundation

/// A resolved Bible target for the debug annotate/note providers — which
/// scripture unit a canned `bible.annotate` / `bible.note` tool call should
/// attach to. Mirrors the position fields of `AnnotateBibleTool` /
/// `NoteBibleTool` (`target` is `"book"` / `"chapter"` / `"verse"`), so a
/// provider maps it straight into the tool's `JSONValue` input.
///
/// DEBUG-only: exists solely to drive the fake Bible-tool providers without
/// a real LLM. See `DebugAnnotateLLMProvider` / `DebugNoteLLMProvider`.
struct DebugBibleTarget: Equatable {
    /// `"book"`, `"chapter"`, or `"verse"` — the tool's `target` enum.
    let target: String
    /// Three-letter UPPERCASE book code, e.g. `"ROM"`, `"JHN"`, `"1CO"`.
    let bookId: String
    let chapterNumber: Int?
    let verseStart: Int?
    let verseEnd: Int?

    /// Resolve a target from the turn's messages, in precedence order:
    /// 1. the headless dispatcher's structured `Reference id: <sourceID>`
    ///    line (`BibleAnnotateDispatcher.prompt`), so the verse-tap "Add
    ///    annotation" path lands on the exact tapped target;
    /// 2. a free-text reference the user typed (e.g. "annotate Romans
    ///    8:28-30"), matched against `Core.BibleBookIndex`;
    /// 3. a fixed John 3:16 fallback when neither is present.
    static func parse(from messages: [LLMMessage]) -> DebugBibleTarget {
        // (1) Scan every message for the dispatcher's `Reference id:` line —
        // it arrives as a user turn, but scanning all turns is cheap and
        // robust to future briefing tweaks.
        for text in allTexts(in: messages) {
            if let target = parseReferenceIDLine(in: text) { return target }
        }
        // (2) Free-text reference in the most recent user turn only — older
        // turns are prior context, not this turn's request.
        if let lastUser = messages.last(where: { $0.role == .user }) {
            let userText = texts(in: lastUser).joined(separator: " ")
            if let target = parseFreeText(userText) { return target }
        }
        // (3) Fallback.
        return DebugBibleTarget(
            target: "verse", bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 16
        )
    }

    // MARK: - Structured `Reference id:` line

    /// Parse the dispatcher's `Reference id: <sourceID>` line if present.
    /// `sourceID` follows `BibleAnnotationTargetSpec.id` grammar:
    /// `book:ROM`, `chapter:ROM:8`, `verse:ROM:8:28:30`.
    static func parseReferenceIDLine(in text: String) -> DebugBibleTarget? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let marker = line.range(of: "Reference id:") else { continue }
            let sourceID = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            if let target = parse(sourceID: sourceID) { return target }
        }
        return nil
    }

    /// Parse a `BibleAnnotationTargetSpec.id`-shaped string into a target.
    static func parse(sourceID: String) -> DebugBibleTarget? {
        let parts = sourceID.split(separator: ":").map(String.init)
        guard let kind = parts.first else { return nil }
        switch kind {
        case "book" where parts.count >= 2:
            return DebugBibleTarget(
                target: "book", bookId: parts[1],
                chapterNumber: nil, verseStart: nil, verseEnd: nil
            )
        case "chapter" where parts.count >= 3:
            guard let chapter = Int(parts[2]) else { return nil }
            return DebugBibleTarget(
                target: "chapter", bookId: parts[1],
                chapterNumber: chapter, verseStart: nil, verseEnd: nil
            )
        case "verse" where parts.count >= 5:
            guard let chapter = Int(parts[2]),
                  let verseStart = Int(parts[3]),
                  let verseEnd = Int(parts[4]) else { return nil }
            return DebugBibleTarget(
                target: "verse", bookId: parts[1],
                chapterNumber: chapter, verseStart: verseStart, verseEnd: verseEnd
            )
        default:
            return nil
        }
    }

    // MARK: - Free-text reference

    /// Match a typed reference like "Romans 8:28-30", "Psalm 23", or a bare
    /// book name against `BibleBookIndex`. Case-insensitive (debug
    /// convenience — the production linkifier is stricter); longest book
    /// spelling first so "1 John" wins over "John". Returns the narrowest
    /// target the text supports: verse range → chapter → whole book.
    static func parseFreeText(_ text: String) -> DebugBibleTarget? {
        // Pick the book mention that appears *earliest* in the text (tie broken
        // by the longest spelling, which `spellingsLongestFirst` yields first),
        // so "John 3:16 — compare with 1 Corinthians" resolves to John, not the
        // later book. Matched case-insensitively against the original `text`
        // (one index domain — slicing `text` with an index taken from a
        // separately-lowercased string is unsound when lowercasing changes
        // length) and word-bounded so a book name embedded in a larger word
        // (e.g. "Romans" inside "Romansesque") doesn't match.
        var best: (range: Range<String.Index>, entry: BibleBookEntry)?
        for (spelling, entry) in BibleBookIndex.spellingsLongestFirst {
            guard let range = text.range(of: spelling, options: .caseInsensitive),
                  isWordBounded(range, in: text) else { continue }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = (range, entry)
            }
        }
        guard let match = best else { return nil }

        // A `chapter:verse[-verseEnd]` or bare chapter must *immediately* follow
        // the book name (only whitespace between), so a stray number elsewhere
        // in the sentence ("Romans, meeting at 8:30") isn't mistaken for a
        // citation. `prefixMatch` anchors to the start of the remainder.
        let remainder = text[match.range.upperBound...]
        if let verse = remainder.prefixMatch(of: Self.verseRangeRegex),
           let chapter = verse.output[1].substring.flatMap({ Int($0) }),
           let verseStart = verse.output[2].substring.flatMap({ Int($0) }) {
            let verseEnd = verse.output[3].substring.flatMap { Int($0) } ?? verseStart
            return DebugBibleTarget(
                target: "verse", bookId: match.entry.id,
                chapterNumber: chapter, verseStart: verseStart, verseEnd: verseEnd
            )
        }
        if let chapterOnly = remainder.prefixMatch(of: Self.chapterRegex),
           let chapter = chapterOnly.output[1].substring.flatMap({ Int($0) }) {
            return DebugBibleTarget(
                target: "chapter", bookId: match.entry.id,
                chapterNumber: chapter, verseStart: nil, verseEnd: nil
            )
        }
        return DebugBibleTarget(
            target: "book", bookId: match.entry.id,
            chapterNumber: nil, verseStart: nil, verseEnd: nil
        )
    }

    /// Whether `range` is flanked by non-alphanumeric characters (or string
    /// ends) — so a book spelling only matches as a whole word.
    private static func isWordBounded(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    /// Leading whitespace then `chapter:verse` with an optional `-verseEnd`
    /// (e.g. ` 8:28-30`). Anchored via `prefixMatch` at the call site. Built at
    /// runtime to dodge regex-literal parsing ambiguity (`?/`); computed (not
    /// stored) because `Regex` isn't `Sendable`.
    private static var verseRangeRegex: Regex<AnyRegexOutput> {
        // Compile-constant pattern: an invalid literal is a programmer error, caught on first run.
        // swiftlint:disable:next force_try
        try! Regex(#"\s*(\d+)\s*:\s*(\d+)(?:\s*-\s*(\d+))?"#)
    }
    /// Leading whitespace then a bare chapter number — the chapter, when no
    /// `chapter:verse` follows (e.g. "Romans 8").
    private static var chapterRegex: Regex<AnyRegexOutput> {
        // Compile-constant pattern: an invalid literal is a programmer error, caught on first run.
        // swiftlint:disable:next force_try
        try! Regex(#"\s*(\d+)"#)
    }

    // MARK: - Helpers

    private static func allTexts(in messages: [LLMMessage]) -> [String] {
        messages.flatMap { texts(in: $0) }
    }

    private static func texts(in message: LLMMessage) -> [String] {
        message.content.compactMap { block in
            if case .text(let value) = block { return value }
            return nil
        }
    }
}
#endif
