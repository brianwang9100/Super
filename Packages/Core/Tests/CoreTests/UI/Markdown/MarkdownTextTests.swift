import Foundation
import Testing
@testable import Core

@Suite("MarkdownText")
@MainActor
struct MarkdownTextTests {
    @Test("default path leaves input verbatim")
    func defaultPathVerbatim() {
        let raw = "this has an unclosed **emphasis"
        let view = MarkdownText(raw)
        #expect(view._resolvedText == raw)
    }

    @Test("partial path routes through autocloser for an unclosed fence")
    func partialPathClosesFence() {
        let raw = """
        ```swift
        let x = 1
        """
        let view = MarkdownText(raw, treatAsPartial: true)
        #expect(view._resolvedText == MarkdownAutocloser.close(raw))
        #expect(view._resolvedText.hasSuffix("```"))
    }

    @Test("partial path routes through autocloser for trailing emphasis with whitespace")
    func partialPathTrimsTrailingEmphasis() {
        // Only whitespace-followed markers are removed; choose that shape to prove cleanup runs.
        let view = MarkdownText("this is ** ", treatAsPartial: true)
        #expect(view._resolvedText == "this is")
    }

    @Test("verse references in the persisted path are linkified")
    func defaultPathLinkifiesVerseReference() {
        let view = MarkdownText("See John 3:16 for context.")
        #expect(view._resolvedText.contains("[John 3:16](super://bible/verse?book=JHN&chapter=3&verses=16)"))
    }

    @Test("verse references in the streaming partial path are linkified")
    func partialPathLinkifiesVerseReferenceAfterAutoclose() {
        let view = MarkdownText("Genesis 1:1 says ** ", treatAsPartial: true)
        let resolved = view._resolvedText
        #expect(resolved.contains("[Genesis 1:1](super://bible/verse?book=GEN&chapter=1&verses=1)"))
        #expect(!resolved.contains("** "))
    }
}
