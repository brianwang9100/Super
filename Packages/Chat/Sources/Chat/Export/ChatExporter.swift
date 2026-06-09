import Core
import Foundation

/// Assembles a ``ChatArchive`` from persisted conversations. Protocol-typed
/// so the export controller depends on a seam the tests can fake (per
/// AGENTS.md §Testing §1), not a concrete repository graph.
public protocol ChatExporter: Sendable {
    /// Build the full "chats only" archive. Honors task cancellation —
    /// callers run this inside a cancellable `Task`.
    func export() async throws -> ChatArchive
}

/// Inert ``ChatExporter`` that yields an empty archive. Used as the export
/// seam for view-model fixtures (snapshots, previews) constructed without the
/// message/tool-call repositories — those render the phase directly via the
/// controller's snapshot seam, so the exporter is never actually run.
struct EmptyChatExporter: ChatExporter {
    let clock: Clock
    func export() async throws -> ChatArchive {
        ChatArchive(exportedAt: clock.now(), conversations: [])
    }
}

/// Repository-backed ``ChatExporter``. Reads through the same repositories
/// the rest of Chat uses rather than touching GRDB directly, so soft-delete
/// and ordering semantics stay in one place.
public struct LiveChatExporter: ChatExporter {
    private let conversationRepository: any ConversationRepository
    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let clock: Clock

    public init(
        conversationRepository: any ConversationRepository,
        messageRepository: any MessageRepository,
        toolCallRepository: any ToolCallRepository,
        clock: Clock
    ) {
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.toolCallRepository = toolCallRepository
        self.clock = clock
    }

    public func export() async throws -> ChatArchive {
        // `listActive()` already drops soft-deleted rows; filter to `.user`
        // so transient dispatcher conversations (bible.annotate) never leak
        // into the export.
        let conversations = try await conversationRepository.listActive()
            .filter { $0.kind == .user }

        var exported: [ChatArchive.Conversation] = []
        exported.reserveCapacity(conversations.count)

        for conversation in conversations {
            try Task.checkCancellation()

            let messages = try await messageRepository.fetchAll(conversationId: conversation.id)
            // One fetch per conversation, grouped by message, instead of a
            // fetch per message.
            let toolCalls = try await toolCallRepository.fetchByConversation(conversation.id)
            var toolCallsByMessage: [String: [ToolCallRecord]] = [:]
            for call in toolCalls {
                toolCallsByMessage[call.messageId, default: []].append(call)
            }

            let exportedMessages = messages.map { message in
                ChatArchive.Message(
                    id: message.id,
                    role: message.role.rawValue,
                    content: message.content,
                    thinkingContent: message.thinkingContent,
                    createdAt: message.createdAt,
                    toolCalls: (toolCallsByMessage[message.id] ?? []).map(Self.exportToolCall)
                )
            }

            exported.append(
                ChatArchive.Conversation(
                    id: conversation.id,
                    title: conversation.title,
                    createdAt: conversation.createdAt,
                    updatedAt: conversation.updatedAt,
                    messages: exportedMessages
                )
            )
        }

        return ChatArchive(exportedAt: clock.now(), conversations: exported)
    }

    /// Map a stored tool call into its archive form, decoding the
    /// `parameters`/`result` JSON-string columns into real nested JSON. A
    /// column that fails to decode (corrupt row) falls back to a string
    /// value so one bad row never sinks the whole export.
    private static func exportToolCall(_ record: ToolCallRecord) -> ChatArchive.ToolCall {
        let parameters = (try? record.decodedParameters()) ?? .string(record.parameters)
        let result: JSONValue? = record.result.map { raw in
            (try? record.decodedResult()).flatMap { $0 } ?? .string(raw)
        }
        return ChatArchive.ToolCall(
            id: record.id,
            toolName: record.toolName,
            parameters: parameters,
            result: result,
            status: record.status.rawValue,
            createdAt: record.createdAt,
            completedAt: record.completedAt
        )
    }
}
