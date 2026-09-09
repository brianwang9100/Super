import Foundation
import Testing
@testable import Bible

@Suite("Annotation sheet request")
struct AnnotationSheetRequestTests {
    @Test("unloaded is distinct from an authoritative empty read")
    @MainActor
    func emptyRead() throws {
        let database = try BibleDatabase.makeInMemory()
        let request = AnnotationSheetRequest(spec: .book(bookId: "ROM"), completedRequestID: "r")
        #expect(AnnotationSheetRequest.defaultValue == nil)
        let snapshot = try database.queue.read { try request.fetch($0) }
        #expect(snapshot?.records == [])
        #expect(snapshot?.completedRequestID == "r")
    }

    @Test("the completion token forces request inequality for the same target")
    func equality() {
        let spec = BibleAnnotationTargetSpec.book(bookId: "ROM")
        let initial = AnnotationSheetRequest(spec: spec, completedRequestID: nil)
        let completed = AnnotationSheetRequest(spec: spec, completedRequestID: "r")
        #expect(initial != completed)
        #expect(completed == AnnotationSheetRequest(spec: spec, completedRequestID: "r"))
        #expect(completed != AnnotationSheetRequest(spec: .book(bookId: "GEN"), completedRequestID: "r"))
    }

    @Test("tagged query retains the underlying exact-target filtering")
    func targetFiltering() async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleAnnotationRepository(database: database)
        for chapter in [8, 9] {
            try await repository.replace(
                target: .chapter, bookId: "ROM", chapterNumber: chapter,
                verseStart: nil, verseEnd: nil,
                inserting: [BibleAnnotationRecord(
                    id: "chapter-\(chapter)", target: .chapter, bookId: "ROM", chapterNumber: chapter,
                    summary: "Summary", source: .user, modelId: "m", createdAt: .distantPast
                ),]
            )
        }
        let request = AnnotationSheetRequest(
            spec: .chapter(bookId: "ROM", chapterNumber: 8), completedRequestID: "completed"
        )
        let snapshot = try await database.queue.read { try request.fetch($0) }
        #expect(snapshot?.records.map(\.id) == ["chapter-8"])
        #expect(snapshot?.completedRequestID == "completed")
    }
}
