import Foundation
import Testing
@testable import Chat

/// Tests for ``MarkdownAutocloser``'s passes over a partial markdown
/// string — closing dangling fenced code blocks, stripping incomplete
/// links/images, and trimming unmatched trailing emphasis markers so
/// the in-flight streaming text renders without flipping the rest of
/// the message into a code block or a bold run when the closer hasn't
/// arrived yet.
///
/// The closer is a pure `String -> String` helper; tests assert the
/// exact returned string for each input shape and rely on no SwiftUI
/// or MarkdownUI state.
@Suite("MarkdownAutocloser")
struct MarkdownAutocloserTests {
    // MARK: - Passthrough

    @Test("balanced markdown is returned unchanged")
    func balancedPassthrough() {
        let input = """
        # Heading

        Some **bold** and *italic* prose with `inline code` and a
        [link](https://example.com).

        ```swift
        let x = 1
        ```

        More prose after the fence.
        """
        #expect(MarkdownAutocloser.close(input) == input)
    }

    @Test("empty input is returned unchanged")
    func emptyPassthrough() {
        #expect(MarkdownAutocloser.close("") == "")
    }

    @Test("plain text without markers is returned unchanged")
    func plainPassthrough() {
        let input = "just some words with no markdown at all"
        #expect(MarkdownAutocloser.close(input) == input)
    }

    // MARK: - Fence autoclose

    @Test("unclosed backtick fence gets a synthetic closing fence")
    func unclosedBacktickFence() {
        let input = """
        Here is some code:

        ```swift
        let x = 1
        let y = 2
        """
        let expected = """
        Here is some code:

        ```swift
        let x = 1
        let y = 2
        ```
        """
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    @Test("unclosed tilde fence gets a synthetic tilde closer")
    func unclosedTildeFence() {
        let input = """
        ~~~python
        print("hi")
        """
        let expected = """
        ~~~python
        print("hi")
        ~~~
        """
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    @Test("fence open on the very last line still gets closed")
    func fenceJustOpened() {
        let input = "intro\n\n```"
        let expected = "intro\n\n```\n```"
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    @Test("quadruple-backtick fence is closed with a matching-length closer")
    func unclosedQuadrupleBacktickFence() {
        // CommonMark requires the closing fence to have at least as
        // many marker characters as the opener — a 3-backtick closer
        // wouldn't close a 4-backtick fence and the rest of the
        // message would still render inside the code block.
        let input = """
        ````swift
        let backticks = "```"
        """
        let expected = """
        ````swift
        let backticks = "```"
        ````
        """
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    @Test("balanced fence is left alone")
    func balancedFence() {
        let input = """
        ```
        body
        ```
        trailing text
        """
        #expect(MarkdownAutocloser.close(input) == input)
    }

    @Test("triple-backtick lines inside a balanced fence pair do not double-close")
    func multipleBalancedFences() {
        let input = """
        ```
        first block
        ```

        middle prose

        ```
        second block
        ```
        """
        #expect(MarkdownAutocloser.close(input) == input)
    }

    // MARK: - Link / image strip

    @Test("dangling link label drops back to literal text")
    func danglingLinkLabel() {
        // No closing `]` — render the `[` as a literal.
        let input = "see [link label without a close"
        let expected = "see link label without a close"
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    @Test("link label closed but url unfinished strips back to label text")
    func danglingLinkUrl() {
        let input = "see [my link](htt"
        let expected = "see my link"
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    @Test("dangling image strips back to its alt text")
    func danglingImage() {
        let input = "before ![alt text](htt"
        let expected = "before alt text"
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    @Test("completed link earlier in the string is preserved when tail has a new dangling link")
    func mixedCompleteAndDanglingLinks() {
        let input = "see [first](https://a.com) and also [second"
        let expected = "see [first](https://a.com) and also second"
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    // MARK: - Trailing emphasis trim

    @Test("trailing double-asterisk run is trimmed")
    func trailingDoubleAsterisk() {
        #expect(MarkdownAutocloser.close("this is **") == "this is")
    }

    @Test("trailing single asterisk is trimmed")
    func trailingSingleAsterisk() {
        #expect(MarkdownAutocloser.close("this is *") == "this is")
    }

    @Test("trailing underscore run is trimmed")
    func trailingUnderscore() {
        #expect(MarkdownAutocloser.close("emphasis __") == "emphasis")
    }

    @Test("trailing backtick is trimmed")
    func trailingBacktick() {
        #expect(MarkdownAutocloser.close("here is `") == "here is")
    }

    @Test("unmatched emphasis with body content after the marker is left alone")
    func unmatchedEmphasisWithBodyIsPreserved() {
        // The `**` opened a bold run that has body characters but no
        // closer yet. CommonMark renders the unclosed marker as a
        // literal `**` (no bold styling), so leaving the input alone
        // matches what the persisted row will render once a closer
        // arrives. Trimming mid-string here would also corrupt
        // intraword markers like `snake_case` — see the dedicated
        // regression tests below.
        #expect(MarkdownAutocloser.close("this is **partial") == "this is **partial")
    }

    // MARK: - Regression — must not corrupt routine prose

    @Test("intraword underscore is preserved (snake_case)")
    func intrawordUnderscoreIsPreserved() {
        #expect(MarkdownAutocloser.close("call snake_case here") == "call snake_case here")
    }

    @Test("single asterisk between tokens is preserved (math/expression)")
    func singleAsteriskInExpressionIsPreserved() {
        #expect(MarkdownAutocloser.close("compute 2 * 3 then add") == "compute 2 * 3 then add")
    }

    @Test("solitary backtick in prose is preserved")
    func solitaryBacktickInProseIsPreserved() {
        #expect(MarkdownAutocloser.close("press the ` key to open") == "press the ` key to open")
    }

    @Test("balanced link whose label contains an underscore is preserved")
    func linkLabelWithUnderscoreIsPreserved() {
        #expect(MarkdownAutocloser.close("see [my_link](https://example.com)") == "see [my_link](https://example.com)")
    }

    @Test("balanced emphasis is left alone")
    func balancedEmphasis() {
        #expect(MarkdownAutocloser.close("this is **bold** done") == "this is **bold** done")
        #expect(MarkdownAutocloser.close("this is *italic* done") == "this is *italic* done")
        #expect(MarkdownAutocloser.close("this is `code` done") == "this is `code` done")
    }

    // MARK: - Precedence: fence wins over inline

    @Test("dangling emphasis inside an unclosed fence does not get trimmed")
    func emphasisInsideUnclosedFence() {
        // The `**` lives inside what will be a code block once closed.
        // The autocloser must close the fence and leave the code body
        // (asterisks included) verbatim.
        let input = """
        ```swift
        let s = "this has **
        """
        let expected = """
        ```swift
        let s = "this has **
        ```
        """
        #expect(MarkdownAutocloser.close(input) == expected)
    }

    @Test("dangling link bracket inside an unclosed fence is preserved as code body")
    func linkInsideUnclosedFence() {
        let input = """
        ```
        let url = "[
        """
        let expected = """
        ```
        let url = "[
        ```
        """
        #expect(MarkdownAutocloser.close(input) == expected)
    }
}
