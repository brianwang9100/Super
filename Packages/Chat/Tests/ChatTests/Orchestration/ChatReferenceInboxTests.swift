import Core
import Testing
@testable import Chat

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

    private func publishAndWait(
        _ event: SuperEvent,
        on bus: SuperEventBus,
        inbox: ChatReferenceInbox
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Arm before publishing so event delivery cannot outrun the seam.
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
        #expect(inbox.pendingAttention == ComposerAttentionRequest(startNew: false))
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
        // References must survive an unmounted chat screen.
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

    @Test func startNewConversationEventCarriesStartNewIntent() async {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)

        await publishAndWait(
            .recordAddedToChat(reference: reference("a"), startNewConversation: true),
            on: bus, inbox: inbox
        )

        #expect(inbox.pendingAttention == ComposerAttentionRequest(startNew: true))
        #expect(inbox.consumeAttention() == ComposerAttentionRequest(startNew: true))
        #expect(inbox.pendingAttention == nil)
        #expect(inbox.consumeAttention() == nil)
    }

    @Test func everyEventPopulatesPendingAttention() async {
        // Attention drives shell expansion and focus independently of conversation creation.
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)

        await publishAndWait(
            .recordAddedToChat(reference: reference("a"), startNewConversation: false),
            on: bus, inbox: inbox
        )
        #expect(inbox.pendingAttention == ComposerAttentionRequest(startNew: false))
        #expect(inbox.consumeAttention() == ComposerAttentionRequest(startNew: false))
        #expect(inbox.pendingAttention == nil)

        await publishAndWait(
            .recordAddedToChat(reference: reference("b"), startNewConversation: true),
            on: bus, inbox: inbox
        )
        #expect(inbox.pendingAttention == ComposerAttentionRequest(startNew: true))
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

        #expect(inbox.pending == [reference("a")])
    }
}
