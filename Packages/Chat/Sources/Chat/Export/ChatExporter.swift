import Core
import Foundation

public protocol ChatExporter: Sendable {
    /// Exports user-visible chats and honors task cancellation.
    func export() async throws -> ChatArchive
}

struct EmptyChatExporter: ChatExporter {
    let clock: Clock
    func export() async throws -> ChatArchive {
        ChatArchive(exportedAt: clock.now(), conversations: [])
    }
}

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
        let conversations = try await conversationRepository.listActive()
            .filter { $0.kind == .user }

        var exported: [ChatArchive.Conversation] = []
        exported.reserveCapacity(conversations.count)

        for conversation in conversations {
            try Task.checkCancellation()

            let messages = try await messageRepository.fetchAll(conversationId: conversation.id)
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

    // Preserve corrupt JSON as a string so one bad column cannot sink the export.
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
