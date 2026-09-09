import Foundation
import Testing
@testable import Bible

@Suite("Annotation presentation")
struct AnnotationPresentationTests {
    private func row(_ id: String, text: String = "Saved") -> BibleAnnotationRecord {
        BibleAnnotationRecord(
            id: id, target: .chapter, bookId: "ROM", chapterNumber: 8,
            summary: text, source: .user, modelId: "model", createdAt: .distantPast
        )
    }

    @Test("initial wait and live progress hide the previous saved response")
    func live() {
        let snapshot = AnnotationSheetSnapshot(records: [row("old")], completedRequestID: nil)
        let waiting = AnnotationPresentation(
            snapshot: snapshot, draft: .init(requestID: "r", text: "", isComplete: false),
            dispatchStatus: .running(requestId: "r")
        )
        #expect(waiting.text.isEmpty)
        #expect(waiting.isWorking)
        #expect(waiting.isShowingDraft)
        let partial = AnnotationPresentation(
            snapshot: snapshot, draft: .init(requestID: "r", text: "**Partial", isComplete: false),
            dispatchStatus: .running(requestId: "r")
        )
        #expect(partial.text == "**Partial")
        #expect(partial.treatAsPartial)
        #expect(partial.savedRecord?.id == "old")
        #expect(!partial.canReturnToSaved)
    }

    @Test("failure preserves partial text and offers access to a saved response")
    func interrupted() {
        let presentation = AnnotationPresentation(
            snapshot: .init(records: [row("old")], completedRequestID: nil),
            draft: .init(requestID: "r", text: "Partial", isComplete: false),
            dispatchStatus: .failed(message: "Disconnected")
        )
        #expect(presentation.text == "Partial")
        #expect(presentation.errorMessage == "Disconnected")
        #expect(!presentation.isWorking)
        #expect(presentation.canReturnToSaved)
        #expect(presentation.treatAsPartial)
    }

    @Test("before-first-token failure preserves the error without showing stale prose")
    func failureBeforeProgress() {
        let presentation = AnnotationPresentation(
            snapshot: nil, draft: .init(requestID: "r", text: "", isComplete: false),
            dispatchStatus: .failed(message: "No key")
        )
        #expect(presentation.text.isEmpty)
        #expect(presentation.errorMessage == "No key")
        #expect(!presentation.canReturnToSaved)
    }

    @Test("completed draft bridges unloaded and stale query snapshots including reopening")
    func delayedQuery() {
        let draft = BibleAnnotationDraft(requestID: "r", text: "Final", isComplete: true)
        let snapshots: [AnnotationSheetSnapshot?] = [
            nil, .init(records: [], completedRequestID: nil),
            .init(records: [row("old")], completedRequestID: "previous"),
        ]
        for snapshot in snapshots {
            let presentation = AnnotationPresentation(snapshot: snapshot, draft: draft, dispatchStatus: nil)
            #expect(presentation.text == "Final")
            #expect(presentation.isShowingDraft)
            #expect(!presentation.isWorking)
            #expect(!presentation.treatAsPartial)
            #expect(presentation.acknowledgedRequestID == nil)
        }
    }

    @Test("matching fresh query becomes authoritative even after replacement or deletion")
    func freshQueryWins() {
        for records in [[row("new", text: "Final")], [row("external", text: "External")], []] {
            let presentation = AnnotationPresentation(
                snapshot: .init(records: records, completedRequestID: "r"),
                draft: .init(requestID: "r", text: "Final", isComplete: true), dispatchStatus: nil
            )
            #expect(presentation.text == (records.last?.summary ?? ""))
            #expect(presentation.savedRecord == records.last)
            #expect(!presentation.isShowingDraft)
            #expect(presentation.acknowledgedRequestID == "r")
        }
    }

    @Test("an old query acknowledgement cannot hide a retry")
    func retryRace() {
        let presentation = AnnotationPresentation(
            snapshot: .init(records: [row("old")], completedRequestID: "old-request"),
            draft: .init(requestID: "new-request", text: "New partial", isComplete: false),
            dispatchStatus: .running(requestId: "new-request")
        )
        #expect(presentation.text == "New partial")
        #expect(presentation.acknowledgedRequestID == nil)
    }

    @Test("cleared draft follows subsequent external writes")
    func settled() {
        let presentation = AnnotationPresentation(
            snapshot: .init(records: [row("external", text: "External")], completedRequestID: nil),
            draft: nil, dispatchStatus: nil
        )
        #expect(presentation.text == "External")
        #expect(!presentation.isShowingDraft)
        #expect(presentation.acknowledgedRequestID == nil)
    }
}
