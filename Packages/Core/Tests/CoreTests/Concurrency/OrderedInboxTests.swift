import Observation
import Synchronization
import Testing
@testable import Core

@Suite("OrderedInbox")
@MainActor
struct OrderedInboxTests {
    @Test func repeatedValuesRemainSeparateMessages() {
        let inbox = OrderedInbox<String>()
        inbox.enqueue("new")
        inbox.enqueue("new")
        #expect(inbox.drain() == ["new", "new"])
        #expect(inbox.revision == 2)
        #expect(inbox.drain().isEmpty)
    }

    @Test func identicalMessageAfterDrainStillNotifiesObserver() {
        let inbox = OrderedInbox<String>()
        inbox.enqueue("add")
        let revision = inbox.revision
        _ = inbox.drain()
        let changed = Mutex(false)
        withObservationTracking {
            _ = inbox.revision
        } onChange: {
            changed.withLock { $0 = true }
        }
        inbox.enqueue("add")
        #expect(changed.withLock { $0 })
        #expect(inbox.revision == revision + 1)
        #expect(inbox.drain() == ["add"])
    }

    @Test func drainOwnsItsBatchWhileLaterMessagesArrive() {
        let inbox = OrderedInbox<String>()
        inbox.enqueue("first")
        let first = inbox.drain()
        inbox.enqueue("later")
        #expect(first == ["first"])
        #expect(inbox.drain() == ["later"])
    }

    @Test func filteringPreservesSurvivingOrder() {
        let inbox = OrderedInbox<String>()
        for message in ["add", "preview", "new", "preview", "open"] {
            inbox.enqueue(message)
        }
        inbox.remove { $0 == "preview" }
        #expect(inbox.drain() == ["add", "new", "open"])
    }

    @Test func oneSubscriptionPreservesMixedBusOrderBeforeUIDrain() async {
        let bus = SuperEventBus()
        var iterator = await bus.events().makeAsyncIterator()
        let inbox = OrderedInbox<SuperEvent>()
        let reference = RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "KJV/JHN/3/16",
            displayLabel: "John 3:16", citation: "John 3:16 (KJV)", snapshot: "For God so loved", id: "reference"
        )
        let events: [SuperEvent] = [
            .recordAddedToChat(reference: reference, startNewConversation: false),
            .openConversationRequested(id: "existing"),
            .recordAddedToChat(reference: reference, startNewConversation: true),
            .newConversationRequested,
        ]
        for event in events { await bus.publish(event) }
        for _ in events {
            guard let event = await iterator.next() else {
                Issue.record("Registered bus stream ended before delivery")
                return
            }
            inbox.enqueue(event)
        }
        #expect(inbox.drain() == events)
    }
}
