import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `ToolCallRecord`'s `JSONValue` codec helpers.
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

    /// The locally-minted-id marker round-trips and is distinguishable from
    /// every provider's wire-id shape — the property the Gemini adapter relies
    /// on to keep a synthetic id off the wire (audit P1-6).
    @Test func locallyMintedIDIsPrefixedAndRecognized() {
        let minted = ToolCallRecord.locallyMintedID("id-7")
        #expect(minted == "localtoolu_id-7")
        #expect(ToolCallRecord.isLocallyMintedID(minted))
        #expect(!ToolCallRecord.isLocallyMintedID("toolu_abc"))    // Anthropic
        #expect(!ToolCallRecord.isLocallyMintedID("call_abc"))     // OpenAI
        #expect(!ToolCallRecord.isLocallyMintedID("get_weather"))  // bare name
    }
}
