import Core
import Foundation
import SwiftUI

extension MessageList {
    public enum Item: Identifiable, Sendable, Equatable {
        case userBubble(id: String, text: String, references: [VerseReferencePillModel])
        case assistantText(
            id: String,
            thinking: String?,
            thinkingDurationMs: Int?,
            text: String,
            toolCalls: [ToolCallItem],
            sources: [SourceCitationPillModel],
            searchSuggestionsHTML: String?,
            searchSystem: String?,
            searchQuery: String?
        )
        case compactionBanner(id: String, summary: String)

        public var id: String {
            switch self {
            case .userBubble(let id, _, _),
                 .assistantText(let id, _, _, _, _, _, _, _, _),
                 .compactionBanner(let id, _):
                return id
            }
        }
    }

    public struct ToolCallItem: Identifiable, Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case running
            case awaitingConfirmation
            case success
            case failed
        }
        public let id: String
        /// Technical function name; the header uses toolDisplayName.
        public let toolName: String
        public let toolDisplayName: String
        public let parametersJSON: String
        public let resultText: String?
        public let status: Status

        public init(
            id: String,
            toolName: String,
            toolDisplayName: String,
            parametersJSON: String,
            resultText: String?,
            status: Status
        ) {
            self.id = id
            self.toolName = toolName
            self.toolDisplayName = toolDisplayName
            self.parametersJSON = parametersJSON
            self.resultText = resultText
            self.status = status
        }
    }

    public struct StreamingState: Sendable, Equatable {
        public let thinking: String
        /// First thinking delta's time, used by the live duration label.
        public let thinkingStartedAt: Date?
        /// Frozen duration when a partial response is retained after interruption.
        public let thinkingDurationMs: Int?
        public let text: String
        public let isCompacting: Bool

        public init(
            thinking: String,
            thinkingStartedAt: Date? = nil,
            thinkingDurationMs: Int? = nil,
            text: String,
            isCompacting: Bool
        ) {
            self.thinking = thinking
            self.thinkingStartedAt = thinkingStartedAt
            self.thinkingDurationMs = thinkingDurationMs
            self.text = text
            self.isCompacting = isCompacting
        }
    }

    /// Disable retry for voice failures: the default retry resends the last LLM message.
    public typealias ErrorState = ResponseErrorState

    /// An explicit user action that positions a turn at the top. A new
    /// sequence can refocus the same message when retrying or regenerating.
    public struct ScrollRequest: Equatable, Sendable {
        public let messageID: String
        public let sequence: Int

        public init(messageID: String, sequence: Int) {
            self.messageID = messageID
            self.sequence = sequence
        }
    }
}

extension ResponseErrorState {
    public static func noModelConfigured(
        onAddModel: @escaping @MainActor @Sendable () -> Void
    ) -> ResponseErrorState {
        ResponseErrorState(
            message: "Add a model to send messages.",
            actionLabel: "Add model",
            action: onAddModel,
            showsRetry: false,
            kind: .noModelConfigured
        )
    }
}
