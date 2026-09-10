import Foundation

public protocol BibleAnnotationRepository: Sendable {
    /// Orders the exact target group by createdAt ASC, id ASC.
    func list(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> [BibleAnnotationRecord]

    /// Atomically replaces the group; empty inserting deletes it. Every record
    /// must match the supplied target and positions.
    func replace(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?,
        inserting records: [BibleAnnotationRecord]
    ) async throws

    /// Used by preserve mode before generation; verse positions are nil for chapter/book slots.
    func hasAnnotation(
        target: BibleAnnotationTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> Bool

    /// Any verse range counts: preserve mode cannot know the model's chosen ranges in advance.
    func hasVerseAnnotations(bookId: String, chapterNumber: Int) async throws -> Bool

    /// No-op if the row is absent.
    func deleteOne(id: String) async throws

    /// Clears all targets; no-op when empty.
    func deleteAll() async throws
}
