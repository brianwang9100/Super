import Foundation

/// Pure helper that takes a partial markdown string and returns one that
/// renders cleanly through MarkdownUI — closes a dangling fenced code
/// block, strips an incomplete link/image, and removes unmatched inline
/// emphasis markers (`**`, `__`, `*`, `_`, `` ` ``).
///
/// Used by ``MarkdownText`` when invoked with `treatAsPartial: true`
/// from ``StreamingTail`` so the in-flight assistant text doesn't flip
/// the rest of the message into a code block while waiting for a closer,
/// nor render half-written links / dangling emphasis as broken syntax.
///
/// Three passes, in priority order: fenced code block (highest — any
/// dangling fence wins and the inline pass is skipped because everything
/// after the opener is code-block body), then link/image strip, then
/// trailing-marker trim. The helper is pure and `Sendable`.
enum MarkdownAutocloser {
    /// Returns `text` with any unterminated markdown closed/stripped so
    /// the result parses without bleeding state into trailing content.
    ///
    /// Most streamed text is plain prose with no markdown markers at
    /// all, and the three passes each materialize a `[Character]` array
    /// over the full input — so a pre-scan of the UTF-8 view (no
    /// per-grapheme allocation) lets the prose-only path return after
    /// one O(n)-byte walk instead of running the full pipeline at every
    /// flush.
    static func close(_ text: String) -> String {
        if text.isEmpty { return text }
        let signal = scanForMarkers(text)
        if !signal.hasFence && !signal.hasInlineMarker && !signal.hasBracket {
            return text
        }
        if signal.hasFence {
            if let fenceClosed = autocloseFenceIfOpen(text) {
                return fenceClosed
            }
            // Fence-present but balanced — skip the inline passes.
            // They walk the raw string without fence awareness, so a
            // balanced `\`\`\`…\`\`\`` block would count as three
            // unmatched backticks and `\[` / `\]` inside a code body
            // would look like an unclosed link, both corrupting the
            // code. Letting MarkdownUI handle the balanced fence is the
            // safe default; partial-input cleanup is best-effort and
            // skips fenced prose intentionally.
            return text
        }
        var working = text
        if signal.hasBracket {
            working = stripDanglingLinkOrImage(working)
        }
        if signal.hasInlineMarker {
            working = trimUnmatchedInlineMarkers(working)
        }
        return working
    }

    /// One-byte UTF-8 scan that tells `close` which expensive passes
    /// are actually needed. Each marker is ASCII so the byte comparison
    /// is sufficient — no `Character` materialization, no Unicode
    /// normalization. `hasFence` requires a run of 3+ consecutive
    /// `\`` or `~` bytes (CommonMark §4.5) so a single inline backtick
    /// doesn't suppress the inline pass.
    private static func scanForMarkers(_ text: String) -> MarkerSignal {
        var signal = MarkerSignal()
        var currentRun: UInt8 = 0
        var currentRunChar: UInt8 = 0
        for byte in text.utf8 {
            switch byte {
            case 0x60: // `
                signal.hasInlineMarker = true
                if currentRunChar == 0x60 {
                    currentRun &+= 1
                } else {
                    currentRun = 1
                    currentRunChar = 0x60
                }
                if currentRun >= 3 { signal.hasFence = true }
            case 0x7E: // ~
                if currentRunChar == 0x7E {
                    currentRun &+= 1
                } else {
                    currentRun = 1
                    currentRunChar = 0x7E
                }
                if currentRun >= 3 { signal.hasFence = true }
            case 0x2A, 0x5F: // *, _
                signal.hasInlineMarker = true
                currentRun = 0
                currentRunChar = 0
            case 0x5B, 0x21: // [, !
                signal.hasBracket = true
                currentRun = 0
                currentRunChar = 0
            default:
                currentRun = 0
                currentRunChar = 0
            }
        }
        return signal
    }

    private struct MarkerSignal {
        var hasFence = false
        var hasInlineMarker = false
        var hasBracket = false
    }

    /// If the input ends with a fenced code block whose closer hasn't
    /// arrived, returns the input with a synthetic closing fence
    /// appended. Otherwise returns nil so the caller falls through to
    /// the inline passes. Tracks the opener's marker-character count so
    /// a 4+ backtick/tilde fence gets a matching-length closer —
    /// CommonMark requires the closer to be ≥ the opener's length, and
    /// LLMs reach for longer fences when the code body contains literal
    /// `\`\`\`` runs.
    private static func autocloseFenceIfOpen(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var inside = false
        var fenceChar: Character = "`"
        var openerLength = 3
        for line in lines {
            let leading = line.prefix(while: { $0 == " " })
            // CommonMark allows up to 3 leading spaces before a fence
            // marker; 4+ would be an indented code block.
            guard leading.count <= 3 else { continue }
            let body = line.dropFirst(leading.count)
            let firstChar = body.first
            guard firstChar == "`" || firstChar == "~" else { continue }
            let runLength = body.prefix(while: { $0 == firstChar }).count
            guard runLength >= 3 else { continue }
            if !inside {
                inside = true
                fenceChar = firstChar!
                openerLength = runLength
            } else if firstChar == fenceChar && runLength >= openerLength {
                // CommonMark §4.5: a closer carries only whitespace
                // after the marker run. Lines like ```swift inside a
                // markdown-about-markdown body must stay treated as
                // code content, not as a premature closer.
                let afterRun = body.dropFirst(runLength)
                if afterRun.allSatisfy(\.isWhitespace) {
                    inside = false
                }
            }
        }
        if inside {
            return text + "\n" + String(repeating: fenceChar, count: openerLength)
        }
        return nil
    }

    /// Walks the string tracking link/image parser state. If a `[…]`
    /// or `![…]` was opened but never completed (no matching `]`, or
    /// `]` followed by an unterminated `(`), strips the markup and
    /// re-emits the label content as literal text.
    private static func stripDanglingLinkOrImage(_ text: String) -> String {
        let chars = Array(text)
        var openBracket: Int?
        var labelEnd: Int?
        var inUrl = false
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "[":
                openBracket = i
                labelEnd = nil
                inUrl = false
            case "]" where openBracket != nil && labelEnd == nil:
                labelEnd = i
                if i + 1 < chars.count, chars[i + 1] == "(" {
                    inUrl = true
                } else {
                    openBracket = nil
                    labelEnd = nil
                }
            case ")" where inUrl:
                openBracket = nil
                labelEnd = nil
                inUrl = false
            default:
                break
            }
            i += 1
        }
        guard let start = openBracket else { return text }
        var stripStart = start
        if start > 0, chars[start - 1] == "!" {
            stripStart = start - 1
        }
        let labelStart = start + 1
        let labelEndExclusive = labelEnd ?? chars.count
        let label = String(chars[labelStart..<labelEndExclusive])
        let prefix = String(chars[0..<stripStart])
        return prefix + label
    }

    /// Tokenizes the string into emphasis-marker positions and pairs
    /// each marker type left-to-right. Removes the last occurrence of
    /// any odd-count marker *only when that marker sits at the literal
    /// tail of the string* — followed by nothing or by whitespace.
    /// Markers buried in the middle of the string (`snake_case`,
    /// `2 * 3`, `use the ` key`) are left alone: CommonMark won't render
    /// them as emphasis (no flanking pair), so trimming them would
    /// silently eat routine prose. The trim is narrowly scoped to the
    /// "user typed `**` and a closer hasn't arrived yet" shape.
    private static func trimUnmatchedInlineMarkers(_ text: String) -> String {
        var chars = Array(text)
        let tokens = tokenizeMarkers(chars)
        var toRemove: [(start: Int, length: Int)] = []
        for marker in ["**", "__", "`", "*", "_"] {
            let matching = tokens.filter { $0.marker == marker }
            guard matching.count % 2 == 1, let last = matching.last else { continue }
            let tailEnd = last.start + last.length
            // Conservative: only trim when the user has explicitly
            // typed whitespace after the marker (signalling "I'm done
            // with this run"). A marker at the literal end of the
            // buffer is ambiguous mid-stream — it could be an emphasis
            // opener or the head of an intraword character that hasn't
            // arrived yet (e.g., `Hello snake_` before `_case`). Leave
            // it as a literal so MarkdownUI renders the raw character
            // until more input disambiguates.
            let tail = chars[tailEnd..<chars.count]
            guard !tail.isEmpty, tail.allSatisfy(\.isWhitespace) else { continue }
            toRemove.append((last.start, last.length))
        }
        // Descending by start so each removal leaves earlier ranges valid.
        toRemove.sort { $0.start > $1.start }
        for range in toRemove {
            chars.removeSubrange(range.start..<(range.start + range.length))
        }
        while let last = chars.last, last.isWhitespace {
            chars.removeLast()
        }
        return String(chars)
    }

    private struct MarkerToken {
        let start: Int
        let length: Int
        let marker: String
    }

    /// Walks the character array greedily emitting `**`/`__` before
    /// single `*`/`_` so a `**` run isn't double-counted as two `*`s.
    /// Triple-or-longer runs (e.g. `***`) split as `**` + `*`, matching
    /// CommonMark's combined-emphasis tokenization closely enough for
    /// the streaming-tail heuristic.
    private static func tokenizeMarkers(_ chars: [Character]) -> [MarkerToken] {
        var tokens: [MarkerToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                tokens.append(.init(start: i, length: 2, marker: "**"))
                i += 2
            } else if c == "_", i + 1 < chars.count, chars[i + 1] == "_" {
                tokens.append(.init(start: i, length: 2, marker: "__"))
                i += 2
            } else if c == "*" {
                tokens.append(.init(start: i, length: 1, marker: "*"))
                i += 1
            } else if c == "_" {
                tokens.append(.init(start: i, length: 1, marker: "_"))
                i += 1
            } else if c == "`" {
                tokens.append(.init(start: i, length: 1, marker: "`"))
                i += 1
            } else {
                i += 1
            }
        }
        return tokens
    }
}
