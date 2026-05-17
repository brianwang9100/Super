import Testing
@testable import Core

/// Tests for `SuperEventBus`'s broadcast fan-out: every active subscriber
/// receives a published event, events published before a subscriber
/// attaches are missed (the gap the Chat-side inbox covers), and delivery
/// survives a sibling subscriber being dropped.
///
/// Synchronization is by `await` on the stream iterator — never `sleep`.
@Suite("SuperEventBus")
struct SuperEventBusTests {
    private func reference(_ id: String) -> RecordReference {
        RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/JHN/3/\(id)",
            displayLabel: "John 3:\(id)", citation: "John 3:\(id) (WEB)",
            snapshot: "verse \(id)", id: id
        )
    }

    @Test func subscriberReceivesPublishedEvent() async {
        let bus = SuperEventBus()
        let stream = await bus.events()
        var iterator = stream.makeAsyncIterator()

        let event = SuperEvent.recordAddedToChat(reference: reference("a"), startNewConversation: false)
        await bus.publish(event)

        #expect(await iterator.next() == event)
    }

    @Test func everySubscriberReceivesTheSameEvent() async {
        let bus = SuperEventBus()
        let first = await bus.events()
        let second = await bus.events()
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()

        let event = SuperEvent.recordAddedToChat(reference: reference("b"), startNewConversation: true)
        await bus.publish(event)

        #expect(await firstIterator.next() == event)
        #expect(await secondIterator.next() == event)
    }

    @Test func eventPublishedBeforeSubscribeIsMissed() async {
        let bus = SuperEventBus()
        // Published with no subscribers — lost, by design.
        await bus.publish(.recordAddedToChat(reference: reference("early"), startNewConversation: false))

        let stream = await bus.events()
        var iterator = stream.makeAsyncIterator()
        let later = SuperEvent.recordAddedToChat(reference: reference("late"), startNewConversation: false)
        await bus.publish(later)

        // The subscriber only ever sees the post-subscribe event.
        #expect(await iterator.next() == later)
    }

    @Test func deliverySurvivesADroppedSiblingSubscriber() async {
        let bus = SuperEventBus()
        let survivor = await bus.events()
        var iterator = survivor.makeAsyncIterator()
        do {
            // A second subscriber that goes out of scope immediately.
            let doomed = await bus.events()
            _ = doomed.makeAsyncIterator()
        }

        let event = SuperEvent.recordAddedToChat(reference: reference("c"), startNewConversation: false)
        await bus.publish(event)

        #expect(await iterator.next() == event)
    }

    @Test func tracksActiveSubscriberCount() async {
        let bus = SuperEventBus()
        #expect(await bus.subscriberCount == 0)
        let stream = await bus.events()
        _ = stream.makeAsyncIterator()
        #expect(await bus.subscriberCount == 1)
    }
}
