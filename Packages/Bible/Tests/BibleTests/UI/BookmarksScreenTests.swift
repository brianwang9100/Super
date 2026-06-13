import Core
import Foundation
import Testing
@testable import Bible

/// Tests for the Bookmarks applet screen's cross-applet publishes and its
/// factored VoiceOver row label. Tapping an assigned slot publishes
/// `SuperEvent.openRecord` carrying a chapter-only `BibleDeepLink` reference;
/// the shell routes it to the Bible applet and `BibleReferenceInbox` lands
/// the reader. Without these assertions a refactor could drop the publish
/// (the snapshot tests render-only and would still pass) and row taps would
/// silently no-op. `@MainActor` because the screen is a `View` type, whose
/// members are MainActor-isolated.
@Suite("BookmarksScreen event bus")
@MainActor
struct BookmarksScreenTests {
    @Test("row tap publishes openRecord with a chapter-only Bible reference")
    func rowTapPublishesOpenRecord() async throws {
        let bus = SuperEventBus()
        // Subscribe before publishing — the bus does no buffering, so a
        // subscriber added after the publish would miss the event.
        let stream = await bus.events()

        let screen = BookmarksScreen(eventBus: bus)
        // Await the publish task itself — not a timeout — so the event is
        // already buffered on the (unbounded) stream before we drain.
        await screen._openBookmark(bookId: "JHN", chapterNumber: 3)?.value

        let received = try await firstEvent(from: stream, timeout: .seconds(5))
        guard case .openRecord(let reference) = received else {
            Issue.record("expected openRecord, got \(received)")
            return
        }
        // Decode through the same parser the receiving inbox uses, so the
        // assertion covers the exact contract the shell round-trips.
        let link = try #require(BibleDeepLink(reference: reference))
        #expect(link.bookId == "JHN")
        #expect(link.chapter == 3)
        #expect(link.verseStart == nil)
        #expect(link.verseEnd == nil)
    }

    @Test("publish helper no-ops when no bus is wired")
    func publishIsNoOpWithoutBus() {
        // Production always injects a bus via the environment; the guard
        // keeps previews and snapshot renders crash-free.
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
