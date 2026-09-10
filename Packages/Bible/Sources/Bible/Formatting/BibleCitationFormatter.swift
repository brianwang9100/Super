public enum BibleCitationFormatter {
    /// Sorts and deduplicates verses, compressing contiguous runs (e.g. "4-6, 9").
    /// Empty input yields an empty clause.
    public static func verseClause(_ verses: [Int]) -> String {
        let sorted = Array(Set(verses)).sorted()
        guard !sorted.isEmpty else { return "" }

        var runs: [(start: Int, end: Int)] = []
        for number in sorted {
            if let last = runs.last, number == last.end + 1 {
                runs[runs.count - 1].end = number
            } else {
                runs.append((number, number))
            }
        }
        return runs
            .map { $0.start == $0.end ? "\($0.start)" : "\($0.start)-\($0.end)" }
            .joined(separator: ", ")
    }

    /// Empty verses names the whole chapter, e.g. "1 Peter 2".
    public static func cite(bookName: String, chapterNumber: Int, verses: [Int]) -> String {
        let chapter = "\(bookName) \(chapterNumber)"
        let clause = verseClause(verses)
        return clause.isEmpty ? chapter : "\(chapter):\(clause)"
    }
}
