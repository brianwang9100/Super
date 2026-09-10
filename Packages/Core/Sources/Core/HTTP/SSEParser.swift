import Foundation

/// Multiple data lines join with a newline.
public struct SSEEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }

    public var isDone: Bool { data == "[DONE]" }
}

/// Buffers incomplete frames. append emits complete frames; finish flushes the
/// trailing frame. Event IDs and retry hints are ignored.
public struct SSEParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// Retains incomplete trailing frames for the next call.
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

    /// Flushes an unterminated trailing frame when the upstream stream closes.
    public mutating func finish() -> [SSEEvent] {
        let remaining = buffer
        buffer.removeAll(keepingCapacity: false)
        guard !remaining.isEmpty, let event = Self.parseFrame(remaining) else {
            return []
        }
        return [event]
    }

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

    private static func stripField(_ line: Substring, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var remainder = line.dropFirst(prefix.count)
        if remainder.first == " " { remainder = remainder.dropFirst() }
        return String(remainder)
    }
}
