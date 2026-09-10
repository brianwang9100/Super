import Core
import Foundation
import Testing
@testable import Bible

@Suite("BookmarksScreen event bus")
@MainActor
struct BookmarksScreenTests {
    @Test("row tap publishes openRecord with a chapter-only Bible reference")
    func rowTapPublishesOpenRecord() async throws {
        let bus = SuperEventBus()
        // Subscribe first: the bus cannot deliver past events to a new subscriber.
        let stream = await bus.events()

        let screen = BookmarksScreen(eventBus: bus)
        // Drain the publish task before consuming the buffered event.
        await screen._openBookmark(bookId: "JHN", chapterNumber: 3)?.value

        let received = try await firstEvent(from: stream, timeout: .seconds(5))
        guard case .openRecord(let reference) = received else {
            Issue.record("expected openRecord, got \(received)")
            return
        }
        let link = try #require(BibleDeepLink(reference: reference))
        #expect(link.bookId == "JHN")
        #expect(link.chapter == 3)
        #expect(link.verseStart == nil)
        #expect(link.verseEnd == nil)
    }

    @Test("publish helper no-ops when no bus is wired")
    func publishIsNoOpWithoutBus() {
        // Production injects a bus; previews and snapshots must also tolerate nil.
        let screen = BookmarksScreen(eventBus: nil)
        #expect(screen._openBookmark(bookId: "JHN", chapterNumber: 3) == nil)
    }

    @Test("an assigned row's label names the chapter and the tap outcome")
    func assignedRowLabel() {
        #expect(
            BookmarksScreen.rowLabel(color: .gold, citation: "Romans 8")
                == "Gold bookmark on Romans 8. Open chapter"
        )
    }

    private func firstEvent(
        from stream: AsyncStream<SuperEvent>,
        timeout: Duration
    ) async throws -> SuperEvent {
        try await withThrowingTaskGroup(of: SuperEvent?.self) { group in
            group.addTask {
                for await event in stream { return event }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let event = first else { throw EventTimeout() }
            return event
        }
    }

    private struct EventTimeout: Error {}
}
