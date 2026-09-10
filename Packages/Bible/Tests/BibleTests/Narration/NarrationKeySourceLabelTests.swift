import Core
import Testing
@testable import Bible

@Suite("Narration key source labels")
struct NarrationKeySourceLabelTests {
    @Test func uniqueNamesKeepTheModelInParentheses() {
        let sources = [
            ProviderAudioCredential(id: "source-a", name: "Personal", keyRef: "ref-a"),
            ProviderAudioCredential(id: "source-b", name: "Work", keyRef: "ref-b"),
        ]

        #expect(NarrationKeySourceLabel.make(for: sources[0], among: sources) == "Use existing key (Personal)")
        #expect(NarrationKeySourceLabel.make(for: sources[1], among: sources) == "Use existing key (Work)")
    }

    @Test(arguments: [false, true])
    func duplicateNamesRemainDistinctWhenSourcesReorder(reversed: Bool) {
        let first = ProviderAudioCredential(id: "source-a", name: "gpt-5.6-luna", keyRef: "ref-a")
        let second = ProviderAudioCredential(id: "source-b", name: "gpt-5.6-luna", keyRef: "ref-b")
        let other = ProviderAudioCredential(id: "source-0", name: "Other model", keyRef: "ref-other")
        let sources = reversed ? [second, other, first] : [first, second, other]

        #expect(NarrationKeySourceLabel.make(for: first, among: sources) == "Use existing key 1 (gpt-5.6-luna)")
        #expect(NarrationKeySourceLabel.make(for: second, among: sources) == "Use existing key 2 (gpt-5.6-luna)")
        #expect(NarrationKeySourceLabel.make(for: other, among: sources) == "Use existing key (Other model)")
    }
}
