import Testing
@testable import Chat

/// Tests for `ChatVerbosity` ranking and display semantics.
@Suite("ChatVerbosity")
struct ChatVerbosityTests {
    @Test func ranksAreOrderedSimpleThinkingVerbose() {
        #expect(ChatVerbosity.simple.rank == 0)
        #expect(ChatVerbosity.thinking.rank == 1)
        #expect(ChatVerbosity.verbose.rank == 2)
    }

    @Test func atLeastIncludesEqual() {
        #expect(ChatVerbosity.thinking.atLeast(.thinking))
        #expect(ChatVerbosity.verbose.atLeast(.thinking))
        #expect(!ChatVerbosity.simple.atLeast(.thinking))
    }

    @Test func displayNamesAreCapitalized() {
        #expect(ChatVerbosity.allCases.map(\.displayName) == ["Simple", "Thinking", "Verbose"])
    }
}
