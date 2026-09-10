enum BibleVerseAnnouncement {
    // Collapse poetry and whitespace so VoiceOver reads continuous prose.
    static func label(verseNumber: Int, verseText: String) -> String {
        let spoken = verseText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "Verse \(verseNumber). \(spoken)"
    }

    // VoiceOver ignores the empty value when no highlight exists.
    static func highlightValue(_ color: BibleHighlightColor?) -> String {
        guard let color else { return "" }
        return "Highlighted \(color.displayName.lowercased())"
    }
}
