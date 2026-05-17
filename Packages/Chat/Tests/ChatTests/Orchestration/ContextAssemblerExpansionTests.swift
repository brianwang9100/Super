import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `ContextAssembler.expandedUserText` — how verse-reference
/// attachments on a user `MessageRecord` are folded into the text handed
/// to the LLM (citation + verbatim snapshot prepended to the typed text).
@Suite("ContextAssembler verse expansion")
struct ContextAssemblerExpansionTests {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func reference(citation: String, snapshot: String, id: String = "r1") -> RecordReference {
        RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/\(id)",
            displayLabel: citation, citation: citation, snapshot: snapshot, id: id
        )
    }

    private func userMessage(content: String, references: [RecordReference]) -> MessageRecord {
        MessageRecord(
            id: "m1", conversationId: "conv-1", role: .user, content: content,
            createdAt: baseDate,
            attachmentsJSON: MessageRecord.encode(MessageAttachments(references: references))
        )
    }

    /// Pull the leading `.text` block off an `LLMMessage`.
    private func text(of message: LLMMessage) -> String? {
        for block in message.content {
            if case .text(let value) = block { return value }
        }
        return nil
    }

    @Test func noAttachmentsReturnsContentUnchanged() {
        let record = userMessage(content: "What does this mean?", references: [])
        #expect(ContextAssembler.expandedUserText(for: record) == "What does this mean?")
    }

    @Test func oneReferencePrependsCitationAndSnapshot() {
        let record = userMessage(
            content: "What does this mean?",
            references: [reference(citation: "John 3:16 (WEB)", snapshot: "For God so loved the world.")]
        )
        #expect(ContextAssembler.expandedUserText(for: record) == """
        [Bible — John 3:16 (WEB)]
        For God so loved the world.

        What does this mean?
        """)
    }

    @Test func multipleReferencesConcatenateInOrderBeforeTheText() {
        let record = userMessage(
            content: "Compare these.",
            references: [
                reference(citation: "John 3:16 (WEB)", snapshot: "verse one", id: "r1"),
                reference(citation: "Romans 8:28 (WEB)", snapshot: "verse two", id: "r2"),
            ]
        )
        #expect(ContextAssembler.expandedUserText(for: record) == """
        [Bible — John 3:16 (WEB)]
        verse one

        [Bible — Romans 8:28 (WEB)]
        verse two

        Compare these.
        """)
    }

    @Test func emptyTypedTextYieldsOnlyTheReferenceBlocks() {
        let record = userMessage(
            content: "",
            references: [reference(citation: "John 3:16 (WEB)", snapshot: "For God so loved the world.")]
        )
        #expect(ContextAssembler.expandedUserText(for: record) == """
        [Bible — John 3:16 (WEB)]
        For God so loved the world.
        """)
    }

    @Test func assembleProjectsTheExpandedUserMessage() throws {
        let assembler = ContextAssembler()
        let record = userMessage(
            content: "Explain.",
            references: [reference(citation: "John 3:16 (WEB)", snapshot: "For God so loved the world.")]
        )
        let model = LLMModel(
            id: "test-model", displayName: "Test",
            supportsThinking: false, supportsTools: true, maxContextTokens: 1_000
        )

        let assembly = try assembler.assemble(
            messages: [record], toolCalls: [], checkpoint: nil, model: model
        )

        #expect(assembly.messages.count == 1)
        #expect(text(of: assembly.messages[0]) == """
        [Bible — John 3:16 (WEB)]
        For God so loved the world.

        Explain.
        """)
    }
}
