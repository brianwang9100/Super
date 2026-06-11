import Testing
@testable import Chat

/// Tripwire for the Chat package's bundled `DefaultSystemPrompt.md`
/// resource. `AppBootstrap` calls `ChatBriefing.load()` to populate
/// the leading system message every conversation sees; a packaging
/// regression (the file dropped from `Package.swift`, renamed,
/// emptied) would silently ship an empty leading system block in
/// production. These assertions fail loudly instead.
@Suite("ChatBriefing")
struct ChatBriefingTests {
    @Test("load returns a non-empty body")
    func loadIsNonEmpty() {
        #expect(ChatBriefing.load().isEmpty == false)
    }

    @Test("load contains the section-header preamble")
    func loadContainsPreamble() {
        // Structural sanity check on the header preamble — guards
        // against a future edit that strips the section explaining
        // the `## <Applet> applet` convention to the LLM.
        #expect(ChatBriefing.load().contains("## Reading the sections that follow"))
    }

    @Test("loadCompact returns a non-empty body materially shorter than the full one")
    func loadCompactIsNonEmptyAndLean() {
        // Same packaging tripwire for `DefaultSystemPrompt.compact.md` —
        // an empty result silently forfeits the compact-tier window savings
        // (ChatSession would fall back to the full persona). The length
        // check guards the point of the file: if the compact variant grows
        // to rival the full one, it has stopped earning its keep.
        let compact = ChatBriefing.loadCompact()
        #expect(compact.isEmpty == false)
        #expect(compact.count < ChatBriefing.load().count / 2)
    }
}
