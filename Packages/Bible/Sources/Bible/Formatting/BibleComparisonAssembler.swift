enum BibleComparisonAssembler {
    static func assemble(primary: BibleChapter, secondary: BibleChapter) -> BibleComparisonContent {
        let left = cells(primary)
        let right = cells(secondary)
        let verses = Set(left.cells.keys).union(right.cells.keys).sorted()
        return BibleComparisonContent(
            rows: verses.map { BibleComparisonRow(verseNumber: $0, primary: left.cells[$0], secondary: right.cells[$0]) },
            primaryTrailingHeadings: left.trailing, secondaryTrailingHeadings: right.trailing
        )
    }

    private static func cells(_ chapter: BibleChapter) -> (cells: [Int: BibleComparisonRow.Cell], trailing: [String]) {
        var cells: [Int: BibleComparisonRow.Cell] = [:]
        var headings: [String] = []
        for paragraph in chapter.paragraphs {
            switch paragraph {
            case .heading(let title): headings.append(title)
            case .prose(let verses), .poetry(let verses):
                for verse in verses {
                    let prior = cells[verse.number]
                    cells[verse.number] = .init(
                        text: prior.map { $0.text + "\n" + verse.text } ?? verse.text,
                        headings: (prior?.headings ?? []) + headings
                    )
                    headings.removeAll()
                }
            }
        }
        return (cells, headings)
    }
}
