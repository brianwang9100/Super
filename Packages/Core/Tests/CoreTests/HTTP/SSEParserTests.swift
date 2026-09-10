import Testing
import Foundation
@testable import Core

@Suite("SSEParser")
struct SSEParserTests {
    @Test func parsesSingleCompleteEvent() {
        var parser = SSEParser()
        let events = parser.append(Data("data: hello\n\n".utf8))
        #expect(events == [SSEEvent(data: "hello")])
    }

    @Test func ignoresCommentLines() {
        var parser = SSEParser()
        let events = parser.append(Data(": ping\ndata: hello\n\n".utf8))
        #expect(events == [SSEEvent(data: "hello")])
    }

    @Test func recognizesDoneSentinel() {
        var parser = SSEParser()
        let events = parser.append(Data("data: [DONE]\n\n".utf8))
        #expect(events.count == 1)
        #expect(events.first?.isDone == true)
    }

    @Test func splitsAcrossChunkBoundaries() {
        var parser = SSEParser()
        let chunk1 = Data("data: par".utf8)
        let chunk2 = Data("tial\n\ndata: complete\n\n".utf8)
        #expect(parser.append(chunk1).isEmpty)
        let events = parser.append(chunk2)
        #expect(events == [SSEEvent(data: "partial"), SSEEvent(data: "complete")])
    }

    @Test func splitsAcrossSeparatorBoundaries() {
        var parser = SSEParser()
        let chunk1 = Data("data: x\n".utf8)
        let chunk2 = Data("\ndata: y\n\n".utf8)
        #expect(parser.append(chunk1).isEmpty)
        let events = parser.append(chunk2)
        #expect(events == [SSEEvent(data: "x"), SSEEvent(data: "y")])
    }

    @Test func handlesCRLFSeparator() {
        var parser = SSEParser()
        let events = parser.append(Data("data: crlf\r\n\r\n".utf8))
        #expect(events == [SSEEvent(data: "crlf")])
    }

    @Test func mixedCRLFAndLF() {
        // Both separator orderings must select the earliest boundary.
        for separators in [("\r\n\r\n", "\n\n"), ("\n\n", "\r\n\r\n")] {
            var parser = SSEParser()
            let events = parser.append(Data("data: first\(separators.0)data: second\(separators.1)".utf8))
            #expect(events == [SSEEvent(data: "first"), SSEEvent(data: "second")])
        }
    }

    @Test func utf8AndCRLFRemainIntactAcrossEveryByteBoundary() {
        let bytes = Data("data: café 🙏\r\n\r\n".utf8)
        for split in 1..<bytes.count {
            var parser = SSEParser()
            #expect(parser.append(Data(bytes.prefix(split))).isEmpty, "split at byte \(split)")
            #expect(parser.append(Data(bytes.dropFirst(split))) == [SSEEvent(data: "café 🙏")])
            #expect(parser.finish().isEmpty)
        }
    }

    @Test func parsesEventName() {
        var parser = SSEParser()
        let events = parser.append(Data("event: message_start\ndata: {}\n\n".utf8))
        #expect(events == [SSEEvent(event: "message_start", data: "{}")])
    }

    @Test func joinsMultipleDataLinesWithNewline() {
        var parser = SSEParser()
        let events = parser.append(Data("data: line1\ndata: line2\n\n".utf8))
        #expect(events == [SSEEvent(data: "line1\nline2")])
    }

    @Test func ignoresIDAndRetryFields() {
        var parser = SSEParser()
        let events = parser.append(Data("id: 42\nretry: 1000\ndata: payload\n\n".utf8))
        #expect(events == [SSEEvent(data: "payload")])
    }

    @Test func dropsFramesWithNoDataAndNoEvent() {
        var parser = SSEParser()
        let events = parser.append(Data(": only-comment\n\n".utf8))
        #expect(events.isEmpty)
    }

    @Test func keepsTrailingPartialUntilCompleted() {
        var parser = SSEParser()
        let events1 = parser.append(Data("data: full\n\ndata: partial".utf8))
        #expect(events1 == [SSEEvent(data: "full")])
        let events2 = parser.append(Data("\n\n".utf8))
        #expect(events2 == [SSEEvent(data: "partial")])
    }

    @Test func finishFlushesUnterminatedFrame() {
        var parser = SSEParser()
        _ = parser.append(Data("data: trailing".utf8))
        let events = parser.finish()
        #expect(events == [SSEEvent(data: "trailing")])
    }

    @Test func finishOnEmptyBufferReturnsNothing() {
        var parser = SSEParser()
        #expect(parser.finish().isEmpty)
    }
}
