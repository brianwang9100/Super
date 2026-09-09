import MarkdownUI
import Testing
@testable import Core

/// Verifies that preview citations lose navigation semantics without losing prose formatting.
@Suite("Markdown Bible citation policy")
struct MarkdownBibleCitationPolicyTests {
    @Test("enabled policy preserves existing automatic linkification")
    func enabledPolicy() {
        let source = "See John 3:16 and [notes](https://example.com)."
        #expect(MarkdownBibleCitationPolicy.enabled.resolve(source) == BibleReferenceLinkifier.linkify(source))
    }

    @Test("plain citations and unrelated source stay byte-for-byte unchanged")
    func plainCitations() {
        let source = "See John 3:16 and [notes](https://example.com).\n\n    literal code"
        #expect(MarkdownBibleCitationPolicy.plainText.resolve(source) == source)
    }

    @Test("internal links retain formatted labels while external links stay active")
    func inlineLinks() {
        expectEquivalent(
            "[**John** 3:16](super://bible/verse?book=JHN&chapter=3&verses=16) and [web](https://example.com).",
            "**John** 3:16 and [web](https://example.com)."
        )
    }

    @Test("reference forms and internal autolinks lose their anchors")
    func referenceLinks() {
        expectEquivalent(
            """
            [John][verse], [verse][], [verse], <super://bible/chapter?book=JHN&chapter=3>.

            [verse]: super://bible/verse?book=JHN&chapter=3&verses=16
            """,
            "John, verse, verse, super://bible/chapter?book=JHN&chapter=3."
        )
    }

    @Test("scheme matching includes uppercase and malformed internal destinations")
    func schemeMatching() {
        expectEquivalent("[one](SuPeR://bible/unknown) [two](super:invalid)", "one two")
    }

    @Test("code syntax survives the rewrite literally")
    func code() {
        let code = """
        `[John](super://bible/x)` and `` ` [John](super://bible/x) ``

            [John](super://bible/x)

        ```markdown
        [John](super://bible/x)
        ```
        """
        expectEquivalent("[John](super://bible/x)\n\n" + code, "John\n\n" + code)
    }

    @Test("lists tables images and strikethrough retain their semantics")
    func richMarkdown() {
        let source = """
        - [x] ~~[John](super://bible/x)~~
          - [**nested**](super://bible/y)

        | Verse | Illustration |
        | --- | --- |
        | [John](super://bible/x) | [![image](https://example.com/a.png)](super://bible/y) |
        """
        let expected = """
        - [x] ~~John~~
          - **nested**

        | Verse | Illustration |
        | --- | --- |
        | John | ![image](https://example.com/a.png) |
        """
        expectEquivalent(source, expected)
    }

    private func expectEquivalent(_ source: String, _ expected: String) {
        let rendered = MarkdownContent(MarkdownBibleCitationPolicy.plainText.resolve(source)).renderHTML()
        #expect(rendered == MarkdownContent(expected).renderHTML())
        #expect(!rendered.lowercased().contains("href=\"super:"))
    }
}
