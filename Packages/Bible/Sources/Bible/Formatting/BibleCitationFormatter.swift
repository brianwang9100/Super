/// Renders a Scripture citation from a book name, chapter, and selected
/// verse numbers — compressing contiguous runs to ranges so `[4, 5, 6, 9]`
/// reads as `"4-6, 9"`.
///
/// A caseless namespace: citation rendering is a pure function with no state.
public enum BibleCitationFormatter {
    /// The verse clause of a citation: contiguous runs collapse to `a-b`,
    /// isolated verses stand alone, and runs join with `", "`.
    ///
    /// The input is deduplicated and sorted first, so repeated or
    /// out-of-order verse numbers are tolerated. An empty input yields the
    /// empty string.
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

    /// A full citation, e.g. `"1 Peter 2:4-6, 9"`. With no verses it names
    /// the whole chapter: `"1 Peter 2"`.
    public static func cite(bookName: String, chapterNumber: Int, verses: [Int]) -> String {
        let chapter = "\(bookName) \(chapterNumber)"
        let clause = verseClause(verses)
        return clause.isEmpty ? chapter : "\(chapter):\(clause)"
    }
}
