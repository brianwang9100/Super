struct BibleComparisonRow: Equatable, Identifiable {
    struct Cell: Equatable {
        let text: String
        let headings: [String]
    }
    let verseNumber: Int
    let primary: Cell?
    let secondary: Cell?
    var id: Int { verseNumber }
}

struct BibleComparisonContent: Equatable {
    let rows: [BibleComparisonRow]
    let primaryTrailingHeadings: [String]
    let secondaryTrailingHeadings: [String]
}
