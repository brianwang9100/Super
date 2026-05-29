import Foundation

/// Writes and reads notes.
///
/// Protocol-typed so the tool dispatcher and the list-sheet coordinator
/// depend on the seam rather than GRDB. Reads coexist with the reactive
/// `ChapterNotesRequest` / `NotesForRangeRequest` / `BookNotesExistenceRequest`
/// `@Query`s: the queries drive glyph visibility and the live list; the
/// imperative `list(...)` here is for paths where pulling a specific target
/// group once is simpler than maintaining a second observation.
///
/// Unlike `BibleAnnotationRepository`'s atomic group-`replace`, notes are
/// edited in place — `insert` adds one note, `update` changes one note's body,
/// and `deleteOne` removes one. There is no whole-group swap.
public protocol BibleNoteRepository: Sendable {
    /// All notes in a target group, ordered newest-first for the list sheet
    /// (`createdAt DESC, id ASC`).
    func list(
        target: BibleNoteTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> [BibleNoteRecord]

    /// Insert one note.
    func insert(_ note: BibleNoteRecord) async throws

    /// Replace one note's body and stamp `updatedAt`. No-op if no row with
    /// `id` exists. Other fields (target, position, source, timestamps other
    /// than `updatedAt`) are immutable after creation.
    func update(id: String, body: String, updatedAt: Date) async throws

    /// Delete one note by id. No-op if no such row exists.
    func deleteOne(id: String) async throws
}
