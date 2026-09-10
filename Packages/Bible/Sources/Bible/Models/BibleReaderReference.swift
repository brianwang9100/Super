import Core

struct BibleReaderReference: Sendable, Equatable {
    let position: BiblePosition
    let translation: BibleTranslation
    let selectedVerses: Set<Int>

    init(position: BiblePosition, translation: BibleTranslation, selectedVerses: Set<Int>) {
        self.position = position
        self.translation = translation
        self.selectedVerses = selectedVerses
    }

    init?(reference: RecordReference) {
        guard reference.appletID == BibleApplet.appletID, reference.kind == "readerPosition" else { return nil }
        let fields = reference.sourceID.split(separator: "/", omittingEmptySubsequences: false)
        guard (4...5).contains(fields.count), fields[0] == "v1",
              let translation = BibleTranslation(rawValue: String(fields[1])),
              let book = BibleBookCatalog.standard.book(id: String(fields[2])),
              let chapter = Self.positiveInteger(fields[3]), chapter <= book.chapterCount else { return nil }

        var verses: [Int] = []
        if fields.count == 5 {
            let parts = fields[4].split(separator: ",", omittingEmptySubsequences: false)
            for part in parts {
                guard let verse = Self.positiveInteger(part), verse > (verses.last ?? 0) else { return nil }
                verses.append(verse)
            }
        }
        self.init(
            position: BiblePosition(bookId: book.id, chapterNumber: chapter),
            translation: translation,
            selectedVerses: Set(verses)
        )
    }

    var recordReference: RecordReference {
        var source = "v1/\(translation.rawValue)/\(position.bookId)/\(position.chapterNumber)"
        if !selectedVerses.isEmpty { source += "/" + selectedVerses.sorted().map(String.init).joined(separator: ",") }
        let name = BibleBookCatalog.standard.book(id: position.bookId)?.name ?? position.bookId
        let citation = BibleCitationFormatter.cite(
            bookName: name, chapterNumber: position.chapterNumber, verses: Array(selectedVerses)
        ) + " (\(translation.rawValue))"
        return RecordReference(
            appletID: BibleApplet.appletID, kind: "readerPosition", sourceID: source,
            displayLabel: citation, citation: citation, snapshot: "", id: "bible-reader:\(source)"
        )
    }

    private static func positiveInteger(_ source: Substring) -> Int? {
        guard let value = Int(source), value > 0, String(value) == source else { return nil }
        return value
    }
}
