import Foundation

/// Writes and reads annotation cards.
///
/// Protocol-typed so the tool dispatcher and the popover view model depend
/// on the seam rather than GRDB. Reads coexist with the reactive
/// `ChapterAnnotationsRequest` / `BookAnnotationsExistenceRequest`
/// `@Query`s: the queries drive bubble visibility in the chapter renderer
/// and book picker; the imperative `list(...)` here is used by the
/// chat-injection composer and the popover's per-card "Add to chat" path,
/// where pulling a specific target group is simpler than maintaining a
/// second observation.
///
/// The write surface is intentionally narrow: `replace(...)` swaps a
/// target group's rows atomically, `deleteOne(id:)` removes a single
/// card, and `deleteAll()` clears every annotation (the hub's "Delete all
/// annotations" reset). No per-row update path — regenerate replaces the
/// whole group, per-card "Delete this card" calls `deleteOne(id:)`, and a
/// future manual-edit feature gets its own typed method when it lands.
public protocol BibleAnnotationRepository: Sendable {
    /// All annotation rows in a target group, in canonical display order
    /// (`category ASC, createdAt ASC, id ASC`) — the same order the
    /// reactive `@Query` paths use, so the chat-injection snapshot matches
    /// what the user sees in the sheet.
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

    /// Delete one annotation row by id. No-op if no such row exists.
    func deleteOne(id: String) async throws

    /// Delete every annotation row across all books, chapters, and verses —
    /// the whole-Bible reset behind the hub's "Delete all annotations". No-op
    /// on an already-empty table.
    func deleteAll() async throws
}
