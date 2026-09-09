import Core
import Testing
@testable import Chat

/// Tests for `ChatReferenceInbox` — the shell-owned buffer that subscribes
/// to the `SuperEventBus` and holds complete reference handoffs until the shell
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

    @Test func everyEventCarriesReferencesAndAdvancesRevision() async {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)
        for startNew in [false, true, true] {
            let previousRevision = inbox.attentionRevision
            await publishAndWait(
                .recordAddedToChat(reference: reference("a"), startNewConversation: startNew),
                on: bus, inbox: inbox
            )
            #expect(inbox.attentionRevision == previousRevision + 1)
            #expect(inbox.consumeAttention() == ComposerAttentionRequest(startNew: startNew, references: [reference("a")]))
            #expect(inbox.consumeAttention() == nil)
        }
    }

    @Test(arguments: [false, true])
    func adjacentMatchingIntentsCoalesceAndDeduplicate(startNew: Bool) async {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)
        for id in ["a", "b", "a"] {
            await publishAndWait(
                .recordAddedToChat(reference: reference(id), startNewConversation: startNew),
                on: bus, inbox: inbox
            )
        }
        #expect(inbox.consumeAttention() == ComposerAttentionRequest(
            startNew: startNew, references: [reference("a"), reference("b")]
        ))
        #expect(inbox.consumeAttention() == nil)
        #expect(inbox.attentionRevision == 3)
    }

    @Test func currentChatHandoffSurvivesNewChatBeforeConsumption() async throws {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)
        await publishAndWait(
            .recordAddedToChat(reference: reference("current"), startNewConversation: false),
            on: bus, inbox: inbox
        )
        await publishAndWait(
            .recordAddedToChat(reference: reference("new"), startNewConversation: true),
            on: bus, inbox: inbox
        )

        let first = try #require(inbox.consumeAttention())
        #expect(!first.startNew)
        #expect(first.references == [reference("current")])
        let second = try #require(inbox.consumeAttention())
        #expect(second.startNew)
        #expect(second.references == [reference("new")])
        #expect(inbox.consumeAttention() == nil)
    }

    @Test func alternatingDestinationsStayOrderedBeforeConsumption() async {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)
        let intents = [false, true, false, true, false]
        for (index, startNew) in intents.enumerated() {
            await publishAndWait(
                .recordAddedToChat(reference: reference(String(index)), startNewConversation: startNew),
                on: bus, inbox: inbox
            )
        }
        for (index, startNew) in intents.enumerated() {
            #expect(inbox.consumeAttention() == ComposerAttentionRequest(
                startNew: startNew, references: [reference(String(index))]
            ))
        }
        #expect(inbox.consumeAttention() == nil)
    }

    @Test func consumedRequestKeepsItsOwnReferencesDuringLaterDelivery() async throws {
        let bus = SuperEventBus()
        let inbox = ChatReferenceInbox()
        await inbox.attach(to: bus)
        await publishAndWait(
            .recordAddedToChat(reference: reference("new"), startNewConversation: true),
            on: bus, inbox: inbox
        )
        let reserved = try #require(inbox.consumeAttention())
        await publishAndWait(
            .recordAddedToChat(reference: reference("later"), startNewConversation: false),
            on: bus, inbox: inbox
        )
        #expect(reserved == ComposerAttentionRequest(startNew: true, references: [reference("new")]))
        #expect(inbox.consumeAttention() == ComposerAttentionRequest(startNew: false, references: [reference("later")]))
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
        #expect(inbox.attentionRevision == 1)
        #expect(inbox.consumeAttention() == ComposerAttentionRequest(startNew: false, references: [reference("a")]))
        #expect(inbox.consumeAttention() == nil)
    }
}
