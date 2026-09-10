enum BibleVerseTextFormatter {
    static func numbered(_ verses: [BibleVerse]) -> String {
        verses.map { "\($0.number). \($0.text)" }.joined(separator: "\n")
    }

    static func plain(_ verses: [BibleVerse]) -> String {
        verses.map(\.text).joined(separator: " ")
    }
}
