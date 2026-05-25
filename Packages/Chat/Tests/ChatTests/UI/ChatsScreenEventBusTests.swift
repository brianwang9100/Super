import Core
import Foundation
import Testing
@testable import Chat

/// Tests for the Chats applet's cross-applet event-bus publishes.
/// Row taps and the `+` button feed `SuperEvent` through the shared
/// `SuperEventBus`; the shell's drain task routes them to
/// `selectConversation` / `startNewChat`. Without these assertions a
/// future refactor could drop the publish entirely (the snapshot
/// tests render-only and would still pass), and tapping a row would
/// silently no-op.
@Suite("ChatsScreen event bus")
@MainActor
struct ChatsScreenEventBusTests {
    @Test("row tap publishes openConversationRequested with the tapped id")
    func rowTapPublishesOpenConversationRequested() async throws {
        let bus = SuperEventBus()
        // Subscribe before publishing — the bus does no buffering, so
        // a subscriber added after the publish would miss the event.
        let stream = await bus.events()

        let screen = ChatsScreen(eventBus: bus)
        screen._openConversation(id: "row-42")

        // Drain the first event with a deadline guard so a regression
        // that silently drops the publish surfaces as a fail rather
        // than a hung suite.
        let received = try await firstEvent(from: stream, timeout: .seconds(1))
        #expect(received == .openConversationRequested(id: "row-42"))
    }

    @Test("plus button publishes newConversationRequested")
    func plusButtonPublishesNewConversationRequested() async throws {
        let bus = SuperEventBus()
        let stream = await bus.events()

        let screen = ChatsScreen(eventBus: bus)
        screen._startNewChat()

        let received = try await firstEvent(from: stream, timeout: .seconds(1))
        #expect(received == .newConversationRequested)
    }

    @Test("publish helpers no-op when no bus is wired")
    func publishesAreNoOpsWithoutBus() {
        // Production never hits this path (the shell always injects a
        // bus into the environment), but the guard exists to keep
        // previews and the bootstrap window crash-free. Smoke-testing
        // it here pins the intent so a future refactor that drops the
        // guard fails loudly.
        let screen = ChatsScreen(eventBus: nil)
        screen._openConversation(id: "ignored")
        screen._startNewChat()
        // Nothing to assert beyond "didn't crash" — the absence of a
        // subscriber means even a real publish would no-op silently.
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
            guard let event = first else {
                throw EventTimeout()
            }
            return event
        }
    }

    private struct EventTimeout: Error {}
}
