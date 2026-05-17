import Core
import Testing
@testable import Chat

/// Tests for `ChatReferenceInbox` — the shell-owned buffer that subscribes
/// to the `SuperEventBus` and holds verse references until a composer
/// drains them. Event delivery is synchronized through the `_onNextEvent`
/// seam (registered before publishing), never `sleep`.
@MainActor
@Suite("ChatReferenceInbox")
struct ChatReferenceInboxTests {
    private func reference(_ id: String) -> RecordReference {
        RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/JHN/3/\(id)",
            displayLabel: "John 3:\(id)", citation: "John 3:\(id) (WEB)",
            snapshot: "verse \(id)", id: id
        )
    }

    /// Publish `event` and return only once the inbox has processed it.
    private func publishAndWait(
        _ event: SuperEvent,
        on bus: SuperEventBus,
        inbox: ChatReferenceInbox
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Arm the seam synchronously, *then* publish — no race.
            inbox._onNextEvent { continuation.resume() }
            Task { await bus.publish(event) }
        }
    }

    @Test func busEventPopulatesPending() async {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)
        let ref = reference("a")

        await publishAndWait(
            .recordAddedToChat(reference: ref, startNewConversation: false),
            on: bus, inbox: inbox
        )

        #expect(inbox.pending == [ref])
        #expect(inbox.wantsNewConversation == false)
    }

    @Test func drainPendingEmptiesTheInbox() async {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)
        await publishAndWait(
            .recordAddedToChat(reference: reference("a"), startNewConversation: false),
            on: bus, inbox: inbox
        )

        let drained = inbox.drainPending()

        #expect(drained == [reference("a")])
        #expect(inbox.pending.isEmpty)
        #expect(inbox.drainPending().isEmpty)
    }

    @Test func referenceBufferedBeforeDrainIsStillDelivered() async {
        // The inbox buffers regardless of whether a composer exists yet —
        // this is what makes delivery guaranteed across an unmounted
        // chat screen. Two references accumulate, then a single drain
        // hands both over.
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)

        await publishAndWait(
            .recordAddedToChat(reference: reference("a"), startNewConversation: false),
            on: bus, inbox: inbox
        )
        await publishAndWait(
            .recordAddedToChat(reference: reference("b"), startNewConversation: false),
            on: bus, inbox: inbox
        )

        #expect(inbox.drainPending() == [reference("a"), reference("b")])
    }

    @Test func startNewConversationEventSetsAndClearsTheFlag() async {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)

        await publishAndWait(
            .recordAddedToChat(reference: reference("a"), startNewConversation: true),
            on: bus, inbox: inbox
        )

        #expect(inbox.wantsNewConversation)
        #expect(inbox.consumeNewConversationRequest())
        #expect(inbox.wantsNewConversation == false)
        #expect(inbox.consumeNewConversationRequest() == false)
    }

    @Test func attachIsIdempotent() async {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)
        await inbox.attach(to: bus)

        await publishAndWait(
            .recordAddedToChat(reference: reference("a"), startNewConversation: false),
            on: bus, inbox: inbox
        )

        // A second subscription would have appended the reference twice.
        #expect(inbox.pending == [reference("a")])
    }
}
