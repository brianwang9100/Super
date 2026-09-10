import Foundation

public protocol BibleNoteRepository: Sendable {
    /// Orders the exact target group by createdAt DESC, id ASC.
    func list(
        target: BibleNoteTarget,
        bookId: String,
        chapterNumber: Int?,
        verseStart: Int?,
        verseEnd: Int?
    ) async throws -> [BibleNoteRecord]

    func insert(_ note: BibleNoteRecord) async throws

    /// Changes only body and updatedAt; no-op for a missing ID.
    func update(id: String, body: String, updatedAt: Date) async throws

    /// No-op if the row is absent.
    func deleteOne(id: String) async throws
}
