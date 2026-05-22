import Foundation
import Testing
@testable import Chat

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
}
