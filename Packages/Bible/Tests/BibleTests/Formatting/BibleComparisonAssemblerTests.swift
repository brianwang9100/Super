import Testing
@testable import Bible

@Suite("Bible translation alignment")
struct BibleComparisonAssemblerTests {
    @Test("aligns actual verse-number union, coalesces fragments and preserves headings and poetry")
    func alignment() {
        let left = BibleChapter(number: 1, paragraphs: [
            .heading("Left heading"), .poetry([.init(number: 1, text: "First\nline")]),
            .prose([.init(number: 1, text: "continued"), .init(number: 3, text: "Third")]), .heading("After"),
        ])
        let right = BibleChapter(number: 1, paragraphs: [
            .prose([.init(number: 1, text: "One"), .init(number: 2, text: "Two")]),
            .heading("Right heading"), .prose([.init(number: 3, text: "Three")]),
        ])
        let result = BibleComparisonAssembler.assemble(primary: left, secondary: right)
        #expect(result.rows.map(\.verseNumber) == [1, 2, 3])
        #expect(result.rows[0].primary?.text == "First\nline\ncontinued")
        #expect(result.rows[0].primary?.headings == ["Left heading"])
        #expect(result.rows[0].primary?.paragraphs == [
            .poetry([.init(number: 1, text: "First\nline")]),
            .prose([.init(number: 1, text: "continued")]),
        ])
        #expect(result.rows[1].primary == nil)
        #expect(result.rows[1].secondary?.text == "Two")
        #expect(result.rows[2].secondary?.headings == ["Right heading"])
        #expect(result.primaryTrailingHeadings == ["After"])
        #expect(left.paragraphs.count == 4)
    }

    @Test("empty inputs remain empty rather than inventing missing verses")
    func empty() {
        let result = BibleComparisonAssembler.assemble(primary: .init(number: 1, paragraphs: []), secondary: .init(number: 1, paragraphs: []))
        #expect(result.rows.isEmpty)
    }
}
