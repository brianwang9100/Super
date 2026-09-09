import Foundation

/// The versioned JSON boundary for navigation history stored on the reader row.
public enum BibleNavigationHistoryPayload {
    /// Encodes a history in the current version 1 envelope.
    public static func encode(_ history: BibleNavigationHistory) throws -> String {
        let envelope = Envelope(
            version: 1,
            entries: history.entries,
            currentIndex: history.currentIndex
        )
        return String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    }

    /// Restores valid history or seeds a new history from the saved position.
    public static func restore(
        from json: String?,
        position: BiblePosition,
        catalog: BibleBookCatalog
    ) -> BibleNavigationHistory {
        let fallback = BibleNavigationHistory(initialPosition: position)
        guard
            let json,
            let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)),
            envelope.version == 1,
            let history = BibleNavigationHistory(
                entries: envelope.entries,
                currentIndex: envelope.currentIndex
            ),
            history.entries.allSatisfy({ entry in
                guard let book = catalog.book(id: entry.bookId) else { return false }
                return (1...book.chapterCount).contains(entry.chapterNumber)
            }),
            history.current == position
        else {
            return fallback
        }
        return history
    }

    private struct Envelope: Codable {
        let version: Int
        let entries: [BiblePosition]
        let currentIndex: Int
    }
}
