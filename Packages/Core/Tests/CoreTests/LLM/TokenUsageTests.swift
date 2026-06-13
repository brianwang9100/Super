import Foundation
import Testing
@testable import Core

/// Coverage for `TokenUsage`'s cache-token fields: backward-compatible Codable
/// decoding of pre-cache payloads, round-tripping with the new fields, and the
/// defaulted-init `Equatable` behavior the provider tests rely on.
@Suite("TokenUsage cache fields")
struct TokenUsageTests {
    @Test("legacy JSON without cache keys decodes with nil cache fields")
    func legacyDecodeLeavesCacheFieldsNil() throws {
        let json = Data(#"{"inputTokens":11,"outputTokens":3}"#.utf8)
        let usage = try JSONDecoder().decode(TokenUsage.self, from: json)
        #expect(usage.inputTokens == 11)
        #expect(usage.outputTokens == 3)
        #expect(usage.cacheReadInputTokens == nil)
        #expect(usage.cacheCreationInputTokens == nil)
    }

    @Test("cache fields round-trip through Codable")
    func cacheFieldsRoundTrip() throws {
        let original = TokenUsage(
            inputTokens: 12,
            outputTokens: 3,
            cacheReadInputTokens: 200,
            cacheCreationInputTokens: 100
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        #expect(decoded == original)
    }

    @Test("defaulted init equals an explicit-nil init")
    func defaultedInitEqualsExplicitNil() {
        let defaulted = TokenUsage(inputTokens: 5, outputTokens: 2)
        let explicit = TokenUsage(
            inputTokens: 5,
            outputTokens: 2,
            cacheReadInputTokens: nil,
            cacheCreationInputTokens: nil
        )
        #expect(defaulted == explicit)
    }

    @Test("a cache-read difference breaks equality")
    func cacheReadDifferenceBreaksEquality() {
        let a = TokenUsage(inputTokens: 5, outputTokens: 2, cacheReadInputTokens: 4)
        let b = TokenUsage(inputTokens: 5, outputTokens: 2)
        #expect(a != b)
    }

    @Test("total ignores cache fields")
    func totalIgnoresCacheFields() {
        let usage = TokenUsage(
            inputTokens: 12,
            outputTokens: 3,
            cacheReadInputTokens: 200,
            cacheCreationInputTokens: 100
        )
        #expect(usage.total == 15)
    }
}
