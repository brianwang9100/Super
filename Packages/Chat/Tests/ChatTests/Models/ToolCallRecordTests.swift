import Core
import Foundation
import Testing
@testable import Chat

@Suite("ToolCallRecord JSON helpers")
struct ToolCallRecordTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRow(parameters: String, result: String? = nil) -> ToolCallRecord {
        ToolCallRecord(
            id: "tc1",
            messageId: "m1",
            conversationId: "c1",
            toolName: "todo.create",
            parameters: parameters,
            result: result,
            status: .pending,
            createdAt: now
        )
    }

    @Test func encodeAndDecodeParametersRoundTrip() throws {
        let value: JSONValue = .object([
            "title": .string("Buy milk"),
            "priority": .int(2),
            "tags": .array([.string("home"), .string("errand")]),
        ])
        let encoded = try ToolCallRecord.encode(value)
        let row = makeRow(parameters: encoded)

        #expect(try row.decodedParameters() == value)
    }

    @Test func decodedResultIsNilForPendingRow() throws {
        let row = makeRow(parameters: "{}")
        #expect(try row.decodedResult() == nil)
    }

    @Test func decodedResultRoundTripsForCompletedRow() throws {
        let result: JSONValue = .object(["createdId": .string("42"), "ok": .bool(true)])
        let row = makeRow(parameters: "{}", result: try ToolCallRecord.encode(result))
        #expect(try row.decodedResult() == result)
    }

    @Test func decodedParametersThrowsOnInvalidJSON() throws {
        let row = makeRow(parameters: "not json")
        #expect(throws: (any Error).self) {
            _ = try row.decodedParameters()
        }
    }

    /// The synthetic prefix lets Gemini keep local persistence IDs off the wire.
    @Test func locallyMintedIDIsPrefixedAndRecognized() {
        let minted = ToolCallRecord.locallyMintedID("id-7")
        #expect(minted == "localtoolu_id-7")
        #expect(ToolCallRecord.isLocallyMintedID(minted))
        #expect(!ToolCallRecord.isLocallyMintedID("toolu_abc"))    // Anthropic
        #expect(!ToolCallRecord.isLocallyMintedID("call_abc"))     // OpenAI
        #expect(!ToolCallRecord.isLocallyMintedID("get_weather"))  // bare name
    }
}
