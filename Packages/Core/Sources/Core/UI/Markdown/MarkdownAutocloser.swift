import Foundation

/// Best-effort cleanup for streaming Markdown. Fence handling takes precedence
/// over link/image cleanup and trailing emphasis trimming to avoid altering code bodies.
enum MarkdownAutocloser {
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
            // Inline passes lack fence awareness and could corrupt backticks/brackets inside code.
            // Leave balanced fenced input to MarkdownUI.
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

    // ASCII marker pre-scan avoids Character arrays for ordinary prose; only 3+
    // backticks/tildes signal a fence, so inline backticks still reach inline cleanup.
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

    // Match the opening fence's marker and length; shorter closers leave long fences open.
    private static func autocloseFenceIfOpen(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var inside = false
        var fenceChar: Character = "`"
        var openerLength = 3
        for line in lines {
            let leading = line.prefix(while: { $0 == " " })
            // Four leading spaces indicate indented code, not a fence.
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
                // A closer can have only trailing whitespace; ```swift inside code is not a closer.
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

    // Strip only the innermost dangling link/image and preserve its label. Nested
    // bracket syntax may briefly show literal outer brackets while streaming.
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

    private static func trimUnmatchedInlineMarkers(_ text: String) -> String {
        var chars = Array(text)
        let tokens = tokenizeMarkers(chars)
        var toRemove: [(start: Int, length: Int)] = []
        for marker in ["**", "__", "`", "*", "_"] {
            let matching = tokens.filter { $0.marker == marker }
            guard matching.count % 2 == 1, let last = matching.last else { continue }
            let tailEnd = last.start + last.length
            // Require trailing whitespace before trimming. A marker at the buffer end may be
            // the start of an intraword sequence whose next chunk has not arrived.
            let tail = chars[tailEnd..<chars.count]
            guard !tail.isEmpty, tail.allSatisfy(\.isWhitespace) else { continue }
            toRemove.append((last.start, last.length))
        }
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

    // Greedily count doubles before singles; this is a streaming heuristic, not a full Markdown parser.
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
