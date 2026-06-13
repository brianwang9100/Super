import Foundation

/// Writes and reads annotation summaries.
///
/// Protocol-typed so the tool executor depends on the seam rather than
/// GRDB. Reads coexist with the reactive `ChapterAnnotationsRequest` /
/// `BookAnnotationsExistenceRequest` `@Query`s: the queries drive the
/// sheet's card and bubble visibility in the chapter renderer and book
/// picker; the imperative `list(...)` here serves callers that need a
/// one-shot pull of a target group without maintaining an observation.
///
/// The write surface is intentionally narrow: `replace(...)` swaps a
/// target group's rows atomically (and with an empty `inserting:` is the
/// sheet's atomic Delete), `deleteOne(id:)` removes a single row, and
/// `deleteAll()` clears every annotation (the hub's "Delete all
/// annotations" reset). No per-row update path — regenerate replaces the
/// whole group, and a future manual-edit feature gets its own typed
/// method when it lands.
public protocol BibleAnnotationRepository: Sendable {
    /// All annotation rows in a target group, ordered
    /// (`createdAt ASC, id ASC`) — the same order the reactive `@Query`
    /// paths use. One row per target is the steady state.
    func list(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> [BibleAnnotationRecord]

    /// Atomically delete every row in a target group and insert the given
    /// replacement rows in a single transaction. Pass an empty
    /// `inserting:` array to use this as a pure delete. The records' own
    /// position fields must match the target-group arguments.
    func replace(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?,
        inserting records: [BibleAnnotationRecord]
    ) async throws

    /// `true` when at least one annotation row already occupies the given
    /// target slot. The bulk runner's preserve mode reads this to skip a unit
    /// before generating (no LLM call) when its slot is already annotated.
    /// `verseStart`/`verseEnd` are `nil` for chapter and book slots.
    func hasAnnotation(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> Bool

    /// `true` when the chapter carries at least one `.verse`-target annotation
    /// (any range). The bulk runner's preserve mode reads this to skip a
    /// `chapterVerses` unit — whose verse ranges aren't known until the model
    /// picks them — when the chapter has already been verse-annotated.
    func hasVerseAnnotations(bookId: String, chapterNumber: Int) async throws -> Bool

    /// Delete one annotation row by id. No-op if no such row exists.
    func deleteOne(id: String) async throws

    /// Delete every annotation row across all books, chapters, and verses —
    /// the whole-Bible reset behind the hub's "Delete all annotations". No-op
    /// on an already-empty table.
    func deleteAll() async throws
}
