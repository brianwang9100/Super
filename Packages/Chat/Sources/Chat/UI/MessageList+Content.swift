import Foundation
import SwiftUI

extension MessageList {
    /// One projected row to display. `MessageRecord`s are projected into
    /// this shape upstream so the view stays free of Core/Chat imports
    /// inside its body. Tool calls render alongside their parent assistant
    /// row as a single sequence of blocks.
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

    /// Inline tool-call presentation rendered under an assistant message.
    /// `status` mirrors `ToolCallStatus` minus the values the UI does not
    /// surface explicitly today (`pending` and `executing` collapse to
    /// `running`; `cancelled` collapses to `failed`). `awaitingConfirmation`
    /// is surfaced so the native web-search proposal can render its inline
    /// approve/skip prompt (and a future destructive tool its own).
    public struct ToolCallItem: Identifiable, Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case running
            case awaitingConfirmation
            case success
            case failed
        }
        public let id: String
        /// Technical function name the LLM called (e.g. `bible.annotate`).
        /// The header uses `toolDisplayName`; this surfaces in the card's
        /// expanded detail only when it differs from the display name.
        public let toolName: String
        /// Friendly, user-facing label resolved from the tool registry, with
        /// a fallback to `toolName` for tools no longer registered.
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

    /// State for the live streaming overlay rendered as ``StreamingTail``.
    public struct StreamingState: Sendable, Equatable {
        public let thinking: String
        /// Wall-clock instant of the first thinking delta in this turn,
        /// captured by the host so the live "Thought for Xs" label can
        /// tick from a `TimelineView`. Nil until thinking starts.
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

    /// State for the compact error pill rendered above the composer by
    /// ``ErrorBanner``. Optionally carries a single trailing action
    /// button (label + closure) — used by the M11 voice-input "Settings"
    /// deep-link banner. When both `actionLabel` and `action` are set the
    /// button replaces the default Retry pill; tapping fires the closure.
    /// Set `showsRetry: false` to suppress the Retry pill entirely (used
    /// for voice-input failures where the parent's `onRetry` would
    /// re-send the last LLM message instead of retrying voice).
    ///
    /// `kind` discriminates banner *origin* so the host can react to a
    /// specific class of error (e.g. auto-clear the "no model" banner
    /// when models become available, without stomping unrelated errors).
    ///
    /// `Equatable` ignores `action` (closure identity isn't meaningful);
    /// SwiftUI re-renders the banner whenever `message`, `actionLabel`,
    /// `showsRetry`, or `kind` change.
    public struct ErrorState: Sendable, Equatable {
        /// Origin discriminator for ``ErrorState``. Lets the host clear
        /// only the matching class of banner when its underlying condition
        /// resolves — e.g. ``noModelConfigured`` is cleared by
        /// `ChatScreenViewModel.setAvailableModels` once at least one
        /// model is available, while a `generic` banner is left alone.
        public enum Kind: Sendable, Equatable {
            case generic
            case noModelConfigured
        }

        public let message: String
        /// Optional verbose detail (e.g. a provider's raw error body) shown
        /// only when the user expands the banner. The banner stays compact by
        /// default — `message` is the one-line summary, `detail` the rest.
        public let detail: String?
        public let actionLabel: String?
        public let action: (@MainActor @Sendable () -> Void)?
        public let showsRetry: Bool
        public let kind: Kind

        public init(
            message: String,
            detail: String? = nil,
            actionLabel: String? = nil,
            action: (@MainActor @Sendable () -> Void)? = nil,
            showsRetry: Bool = true,
            kind: Kind = .generic
        ) {
            self.message = message
            self.detail = detail
            self.actionLabel = actionLabel
            self.action = action
            self.showsRetry = showsRetry
            self.kind = kind
        }

        /// Banner shown when the user tries to send a message but has
        /// no model endpoints configured. The action opens the
        /// "Add Model" sheet via the host-provided callback.
        public static func noModelConfigured(
            onAddModel: @escaping @MainActor @Sendable () -> Void
        ) -> ErrorState {
            ErrorState(
                message: "Add a model to send messages.",
                actionLabel: "Add model",
                action: onAddModel,
                showsRetry: false,
                kind: .noModelConfigured
            )
        }

        public static func == (lhs: ErrorState, rhs: ErrorState) -> Bool {
            lhs.message == rhs.message
                && lhs.detail == rhs.detail
                && lhs.actionLabel == rhs.actionLabel
                && lhs.showsRetry == rhs.showsRetry
                && lhs.kind == rhs.kind
        }
    }

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
