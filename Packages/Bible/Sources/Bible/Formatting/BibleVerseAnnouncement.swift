/// Builds the VoiceOver announcement for a verse span — the label a reader
/// hears when focus lands on a verse, e.g. `"Verse 9. But you are a chosen
/// race…"`, and the value naming its persisted highlight.
///
/// A caseless namespace: announcement rendering is a pure function with no
/// state. Kept apart from the view so it can be unit-tested without a
/// rendered accessibility tree.
enum BibleVerseAnnouncement {
    /// The spoken label for a verse: `"Verse <n>. <text>"`. Poetry line
    /// breaks and any other whitespace runs collapse to single spaces so the
    /// verse reads as continuous prose rather than stalling on each line.
    static func label(verseNumber: Int, verseText: String) -> String {
        let spoken = verseText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "Verse \(verseNumber). \(spoken)"
    }

    /// The spoken value naming the verse's persisted highlight, or the empty
    /// string when the verse carries none — an empty string is ignored by
    /// VoiceOver.
    static func highlightValue(_ color: BibleHighlightColor?) -> String {
        guard let color else { return "" }
        return "Highlighted \(color.displayName.lowercased())"
    }
}
