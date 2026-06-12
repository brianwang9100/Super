import Foundation
import Testing
@testable import Core

/// Tests for ``MarkdownText``'s opt-in partial-input path — when
/// constructed with `treatAsPartial: true`, the text handed to the
/// underlying MarkdownUI view must pass through ``MarkdownAutocloser``
/// so an in-flight streaming string with a dangling fence/link/emphasis
/// renders cleanly. Default construction (`treatAsPartial: false`) must
/// leave the input verbatim so the persisted ``AssistantMessage`` path
/// keeps its current byte-for-byte rendering.
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
        // EOF markers are preserved (see MarkdownAutocloserTests for
        // the rationale); only when whitespace follows the marker do
        // we trim. Picking the whitespace-followed shape gives the
        // best signal that the wiring routes through the autocloser.
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
        // Streaming tail with both a verse reference and a dangling
        // emphasis: the autocloser strips the trailing marker, then the
        // linkifier wraps the verse — both passes run.
        let view = MarkdownText("Genesis 1:1 says ** ", treatAsPartial: true)
        let resolved = view._resolvedText
        #expect(resolved.contains("[Genesis 1:1](super://bible/verse?book=GEN&chapter=1&verses=1)"))
        // Trailing whitespace-emphasis is gone via the autocloser.
        #expect(!resolved.contains("** "))
    }
}
