import Foundation
import Testing

@testable import Chat

@Suite("SlashCommand")
struct SlashCommandTests {

    @Test func recognizesCompactWithExactSpelling() {
        #expect(SlashCommand(rawText: "/compact") == .compact)
    }

    @Test func tolerantToSurroundingWhitespace() {
        #expect(SlashCommand(rawText: "  /compact  ") == .compact)
        #expect(SlashCommand(rawText: "\n/compact\n") == .compact)
    }

    @Test func returnsNilForPlainText() {
        #expect(SlashCommand(rawText: "compact") == nil)
        #expect(SlashCommand(rawText: "Please /compact this chat") == nil)
        #expect(SlashCommand(rawText: "") == nil)
    }

    @Test func unknownSlashCommandReturnsNil() {
        #expect(SlashCommand(rawText: "/clear") == nil)
        #expect(SlashCommand(rawText: "/help") == nil)
    }
}
