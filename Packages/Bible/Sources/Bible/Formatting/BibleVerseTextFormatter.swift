/// Renders verses as a numbered plain-text block — one `"<number>. <text>"`
/// line per verse — for LLM (Large Language Model) tool output and for grounding
/// annotation generation in the exact translation text.
///
/// A caseless namespace: pure formatting with no state, the textual companion to
/// `BibleCitationFormatter`.
enum BibleVerseTextFormatter {
    /// One `"<number>. <text>"` line per verse, newline-joined, in the order
    /// given. An empty input yields the empty string.
    static func numbered(_ verses: [BibleVerse]) -> String {
        verses.map { "\($0.number). \($0.text)" }.joined(separator: "\n")
    }
}
