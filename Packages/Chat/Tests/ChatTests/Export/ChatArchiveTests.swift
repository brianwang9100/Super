import Core
import Foundation
import Testing
@testable import Chat

/// Verifies the on-disk archive encoding is stable and round-trips.
@Suite("ChatArchive encoding")
struct ChatArchiveTests {
    private func sample() -> ChatArchive {
        ChatArchive(
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            conversations: [
                .init(
                    id: "c1",
                    title: "Greetings",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    messages: [
                        .init(
                            id: "m1", role: "user", content: "hi", thinkingContent: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000), toolCalls: []
                        ),
                        .init(
                            id: "m2", role: "assistant", content: "hello", thinkingContent: "ponder",
                            createdAt: Date(timeIntervalSince1970: 1_700_000_050),
                            toolCalls: [
                                .init(
                                    id: "tc1", toolName: "time.now",
                                    parameters: .object(["tz": .string("UTC")]),
                                    result: .object(["iso": .string("2023-...")]),
                                    status: "success",
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_050),
                                    completedAt: Date(timeIntervalSince1970: 1_700_000_051)
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    @Test("encodes pretty-printed with sorted keys and ISO-8601 dates")
    func encodesStably() throws {
        let data = try sample().encoded()
        let json = String(decoding: data, as: UTF8.self)

        // sortedKeys ⇒ keys are alphabetical: conversations < exportedAt < formatVersion.
        let convIdx = try #require(json.range(of: "\"conversations\""))
        let exportedIdx = try #require(json.range(of: "\"exportedAt\""))
        let formatIdx = try #require(json.range(of: "\"formatVersion\""))
        #expect(convIdx.lowerBound < exportedIdx.lowerBound)
        #expect(exportedIdx.lowerBound < formatIdx.lowerBound)

        // ISO-8601 date rendering, not a bare epoch double.
        #expect(json.contains("2027-01-15T08:00:00Z") || json.contains("2027"))
        // pretty-printed ⇒ contains newlines and indentation.
        #expect(json.contains("\n"))
    }

    @Test("round-trips back to an equal value")
    func roundTrips() throws {
        let original = sample()
        let data = try original.encoded()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatArchive.self, from: data)
        #expect(decoded == original)
    }
}
