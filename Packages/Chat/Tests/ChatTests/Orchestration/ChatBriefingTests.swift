import Testing
@testable import Chat

/// Missing or empty bundled prompts silently remove production system instructions.
@Suite("ChatBriefing")
struct ChatBriefingTests {
    @Test("load returns a non-empty body")
    func loadIsNonEmpty() {
        #expect(ChatBriefing.load().isEmpty == false)
    }

    @Test("load contains the section-header preamble")
    func loadContainsPreamble() {
        #expect(ChatBriefing.load().contains("## Reading the sections that follow"))
    }

    @Test("loadCompact returns a non-empty body materially shorter than the full one")
    func loadCompactIsNonEmptyAndLean() {
        // An empty compact prompt falls back to the full persona and forfeits window savings.
        let compact = ChatBriefing.loadCompact()
        #expect(compact.isEmpty == false)
        #expect(compact.count < ChatBriefing.load().count / 2)
    }
}
