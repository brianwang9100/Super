import Foundation

/// One parsed SSE (Server-Sent Events) frame. Multiple `data:` lines in a
/// single frame are joined by `\n`, matching the WHATWG EventSource spec.
public struct SSEEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }

    /// True when this event carries the `[DONE]` end-of-stream sentinel
    /// used by OpenAI-compatible providers.
    public var isDone: Bool { data == "[DONE]" }
}

/// Buffered, partial-chunk-tolerant SSE (Server-Sent Events) frame parser.
///
/// Per the WHATWG EventSource spec, frames are separated by a blank line
/// (`\n\n` or `\r\n\r\n`) and each frame is a sequence of `field: value`
/// lines. Callers pump bytes via `append(_:)` and receive only the events
/// whose frames are complete; trailing partial frames stay in the buffer
/// until either the next `append(_:)` completes them or `finish()` flushes
/// them. Recognized fields are `data:`, `event:`, `id:`, `retry:`, and `:`
/// (comment); everything else is ignored.
public struct SSEParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feed raw bytes from the wire.
    ///
    /// - Parameter data: Bytes received from the upstream HTTP body. Safe to
    ///   pass partial frames; the parser holds the tail until the next
    ///   `append(_:)` or `finish()` completes it.
    /// - Returns: The events whose terminating blank line landed inside (or
    ///   on the boundary of) `data`, in arrival order. Empty if no frame
    ///   completed.
    public mutating func append(_ data: Data) -> [SSEEvent] {
        buffer.append(data)
        var events: [SSEEvent] = []
        while let boundary = nextBoundary(in: buffer) {
            let frame = buffer.subdata(in: 0..<boundary.lowerBound)
            buffer.removeSubrange(0..<boundary.upperBound)
            if let event = Self.parseFrame(frame) {
                events.append(event)
            }
        }
        return events
    }

    /// Flush any unterminated trailing frame. Call when the upstream HTTP
    /// stream closes without a final blank line.
    ///
    /// - Returns: One event if the buffer held a parseable trailing frame,
    ///   otherwise empty.
    public mutating func finish() -> [SSEEvent] {
        let remaining = buffer
        buffer.removeAll(keepingCapacity: false)
        guard !remaining.isEmpty, let event = Self.parseFrame(remaining) else {
            return []
        }
        return [event]
    }

    /// Locates the earliest `\n\n` or `\r\n\r\n` separator in `data`.
    private func nextBoundary(in data: Data) -> Range<Data.Index>? {
        let lf = data.range(of: Data([0x0A, 0x0A]))
        let crlf = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        switch (lf, crlf) {
        case (nil, nil): return nil
        case (let lf?, nil): return lf
        case (nil, let crlf?): return crlf
        case (let lf?, let crlf?): return lf.lowerBound < crlf.lowerBound ? lf : crlf
        }
    }

    /// Parse a single complete frame (sans terminator) into an event.
    private static func parseFrame(_ frame: Data) -> SSEEvent? {
        guard let raw = String(data: frame, encoding: .utf8) else { return nil }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var dataLines: [String] = []
        var eventName: String?
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue }
            if let value = stripField(line, prefix: "data:") {
                dataLines.append(value)
            } else if let value = stripField(line, prefix: "event:") {
                eventName = value
            } else if stripField(line, prefix: "id:") != nil {
                // Last-event-id reconnection isn't used yet; ignored.
            } else if stripField(line, prefix: "retry:") != nil {
                // Reconnect-delay hints aren't honored yet; ignored.
            }
        }
        guard !dataLines.isEmpty || eventName != nil else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }

    /// Drops the `prefix` (and one optional space) from `line`, returning
    /// the field value or nil if the line doesn't match.
    private static func stripField(_ line: Substring, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var remainder = line.dropFirst(prefix.count)
        if remainder.first == " " { remainder = remainder.dropFirst() }
        return String(remainder)
    }
}
