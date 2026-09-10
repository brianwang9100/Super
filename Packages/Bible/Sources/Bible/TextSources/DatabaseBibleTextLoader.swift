import Foundation
import GRDB

/// Reads one indexed chapter JSON blob per navigation, avoiding whole-book decoding.
public struct DatabaseBibleTextLoader: BibleTextLoader {
    private let database: BibleTextDatabase?

    /// Missing or unopenable bundled storage yields nil for every chapter.
    public init() {
        self.database = try? BibleTextDatabase.openBundled()
    }

    /// Share an open database; nil models unavailable bundled storage.
    init(database: BibleTextDatabase?) {
        self.database = database
    }

    public func loadChapter(
        bookId: String, chapterNumber: Int, translation: BibleTranslation
    ) throws -> BibleChapter? {
        guard let database else { return nil }
        let blob = try database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT json FROM chapter WHERE translation = ? AND bookId = ? AND number = ?",
                arguments: [translation.rawValue, bookId, chapterNumber]
            )
        }
        guard let blob else { return nil }
        do {
            return try JSONDecoder().decode(BibleChapter.self, from: Data(blob.utf8))
        } catch {
            // A present but undecodable row is a generator failure, not a missing chapter.
            throw BibleTextLoaderError.malformedResource("\(translation.rawValue)-\(bookId) \(chapterNumber)")
        }
    }
}
