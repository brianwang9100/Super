import Foundation
import GRDB

/// The production `BibleTextLoader`: reads one structured chapter per navigation
/// from the bundled, read-only `bible-text.sqlite`.
///
/// Each `chapter` row stores the source chapter object (`{number, paragraphs}`)
/// as a verbatim JSON blob, so decoding it reconstructs the *identical*
/// `BibleChapter` the per-book JSON would (an exhaustive parity test guards this).
/// This replaces the old whole-book JSON decode: a tiny indexed lookup plus one
/// small decode on the main actor, instead of re-parsing an entire book on every
/// chapter step.
public struct DatabaseBibleTextLoader: BibleTextLoader {
    private let database: BibleTextDatabase?

    /// Production entry point — opens the bundled `bible-text.sqlite`. A missing or
    /// unopenable resource degrades to a loader that returns `nil` for every
    /// chapter (the reader shows its existing "unavailable" state) rather than
    /// crashing, matching the old loader's soft-failure posture.
    public init() {
        self.database = try? BibleTextDatabase.openBundled()
    }

    /// Injection seam: share an already-open database — so the applet opens the
    /// bundle once and builds both this loader and `BundledBibleTextSearcher` from
    /// it — or pass `nil` to model the unavailable-bundle path.
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
            // A row that's present but won't decode is a generator bug, not a
            // missing chapter — surface it rather than silently returning nil.
            throw BibleTextLoaderError.malformedResource("\(translation.rawValue)-\(bookId) \(chapterNumber)")
        }
    }
}
