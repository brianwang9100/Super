import Foundation
import Testing
@testable import Core

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
        // A shorter closer would leave the outer fence open.
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

    @Test("line with an info string inside a fence is not treated as a closer")
    func infoStringLineIsNotACloser() {
        // A language-tagged fence inside code must not close the outer block and trigger
        // a spurious synthetic closer at its real end.
        let input = """
        ```markdown
        example:
        ```swift
        let x = 1
        ```
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

    // MARK: - Trailing emphasis

    @Test("trailing double-asterisk at EOF is preserved as a literal")
    func trailingDoubleAsteriskAtEOFPreserved() {
        #expect(MarkdownAutocloser.close("this is **") == "this is **")
    }

    @Test("trailing single asterisk at EOF is preserved as a literal")
    func trailingSingleAsteriskAtEOFPreserved() {
        #expect(MarkdownAutocloser.close("this is *") == "this is *")
    }

    @Test("trailing underscore at EOF is preserved (avoids mid-stream snake_case corruption)")
    func trailingUnderscoreAtEOFPreserved() {
        // Preserve a partial intraword underscore until the next streaming chunk arrives.
        #expect(MarkdownAutocloser.close("Hello snake_") == "Hello snake_")
    }

    @Test("trailing backtick at EOF is preserved")
    func trailingBacktickAtEOFPreserved() {
        #expect(MarkdownAutocloser.close("here is `") == "here is `")
    }

    @Test("trailing marker followed by explicit whitespace is trimmed")
    func trailingMarkerWithWhitespaceIsTrimmed() {
        #expect(MarkdownAutocloser.close("this is ** ") == "this is")
        #expect(MarkdownAutocloser.close("emphasis __\n") == "emphasis")
    }

    @Test("unmatched emphasis with body content after the marker is left alone")
    func unmatchedEmphasisWithBodyIsPreserved() {
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
