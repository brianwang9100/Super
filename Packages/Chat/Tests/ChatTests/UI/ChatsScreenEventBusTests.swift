import Core
import Foundation
import Testing
@testable import Chat

@Suite("ChatsScreen event bus")
@MainActor
struct ChatsScreenEventBusTests {
    @Test("row tap publishes openConversationRequested with the tapped id")
    func rowTapPublishesOpenConversationRequested() async throws {
        let bus = SuperEventBus()
        // Subscribe before publishing; the bus does not retain events for future subscribers.
        let stream = await bus.events()

        let screen = ChatsScreen(eventBus: bus)
        // Await publication before draining so scheduler delays cannot consume the timeout.
        await screen._openConversation(id: "row-42")?.value

        let received = try await firstEvent(from: stream, timeout: .seconds(5))
        #expect(received == .openConversationRequested(id: "row-42"))
    }

    @Test("plus button publishes newConversationRequested")
    func plusButtonPublishesNewConversationRequested() async throws {
        let bus = SuperEventBus()
        let stream = await bus.events()

        let screen = ChatsScreen(eventBus: bus)
        await screen._startNewChat()?.value

        let received = try await firstEvent(from: stream, timeout: .seconds(5))
        #expect(received == .newConversationRequested)
    }

    @Test("publish helpers no-op when no bus is wired")
    func publishesAreNoOpsWithoutBus() {
        let screen = ChatsScreen(eventBus: nil)
        screen._openConversation(id: "ignored")
        screen._startNewChat()
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
