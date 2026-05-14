import Foundation
import SwiftUI

/// Scrollable transcript: persisted `MessageRecord`s laid out as user
/// bubbles + assistant text/tool blocks, with an optional live streaming
/// overlay tail showing the in-flight assistant text/thinking, and an
/// optional error banner above the composer.
///
/// Persisted assistant text, thinking traces, and the compaction-banner
/// summary all run through ``MarkdownText`` (MarkdownUI + Splash). The
/// streaming tail intentionally stays plain `Text` so we don't re-parse
/// partial markdown on every delta — the cutover happens in
/// `ChatScreenViewModel.handle(.assistantMessageSaved)`.
public struct MessageList: View {
    /// One projected row to display. `MessageRecord`s are projected into
    /// this shape upstream so the view stays free of Core/Chat imports
    /// inside its body. Tool calls render alongside their parent assistant
    /// row as a single sequence of blocks.
    public enum Item: Identifiable, Sendable, Equatable {
        case userBubble(id: String, text: String)
        case assistantText(
            id: String,
            thinking: String?,
            thinkingDurationMs: Int?,
            text: String,
            toolCalls: [ToolCallItem]
        )
        case compactionBanner(id: String, summary: String)

        public var id: String {
            switch self {
            case .userBubble(let id, _),
                 .assistantText(let id, _, _, _, _),
                 .compactionBanner(let id, _):
                return id
            }
        }
    }

    /// Inline tool-call presentation rendered under an assistant message.
    /// `status` mirrors `ToolCallStatus` minus the values the UI does not
    /// surface explicitly today (`pending` and `executing` collapse to
    /// `running`; `awaitingConfirmation` is treated as running for now).
    public struct ToolCallItem: Identifiable, Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case running
            case success
            case failed
        }
        public let id: String
        public let toolName: String
        public let parametersJSON: String
        public let resultText: String?
        public let status: Status

        public init(
            id: String,
            toolName: String,
            parametersJSON: String,
            resultText: String?,
            status: Status
        ) {
            self.id = id
            self.toolName = toolName
            self.parametersJSON = parametersJSON
            self.resultText = resultText
            self.status = status
        }
    }

    public let items: [Item]
    /// Live streaming tail. Rendered as an additional assistant row below
    /// the persisted ones. `nil` when no turn is in flight.
    public let streamingTail: StreamingState?
    /// Error banner state shown above the composer; nil hides the banner.
    public let error: ErrorState?
    public let verbosity: ChatVerbosity
    public let onRetry: () -> Void
    /// Fired when the user taps anywhere on the transcript content (a
    /// message bubble, the spaces between, etc.). `ChatScreen` wires this
    /// to keyboard dismissal. Lives inside `MessageList` because a tap
    /// gesture attached *outside* a `ScrollView` is intercepted by the
    /// scroll view's recognizers and never fires — the gesture must be
    /// inside the scroll content's `LazyVStack`. Attached as a
    /// `simultaneousGesture` so it fires alongside taps on interactive
    /// children (e.g., the `ErrorBanner` retry button) — dismissing the
    /// keyboard immediately before the child action runs is the intended
    /// behavior.
    public let onContentTap: () -> Void

    /// State for the live streaming overlay rendered as ``StreamingTail``.
    public struct StreamingState: Sendable, Equatable {
        public let thinking: String
        /// Wall-clock instant of the first thinking delta in this turn,
        /// captured by the host so the live "Thought for Xs" label can
        /// tick from a `TimelineView`. Nil until thinking starts.
        public let thinkingStartedAt: Date?
        public let text: String
        public let isCompacting: Bool

        public init(
            thinking: String,
            thinkingStartedAt: Date? = nil,
            text: String,
            isCompacting: Bool
        ) {
            self.thinking = thinking
            self.thinkingStartedAt = thinkingStartedAt
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
        public let actionLabel: String?
        public let action: (@MainActor @Sendable () -> Void)?
        public let showsRetry: Bool
        public let kind: Kind

        public init(
            message: String,
            actionLabel: String? = nil,
            action: (@MainActor @Sendable () -> Void)? = nil,
            showsRetry: Bool = true,
            kind: Kind = .generic
        ) {
            self.message = message
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
                && lhs.actionLabel == rhs.actionLabel
                && lhs.showsRetry == rhs.showsRetry
                && lhs.kind == rhs.kind
        }
    }

    public init(
        items: [Item],
        streamingTail: StreamingState? = nil,
        error: ErrorState? = nil,
        verbosity: ChatVerbosity = .simple,
        onRetry: @escaping () -> Void = {},
        onContentTap: @escaping () -> Void = {}
    ) {
        self.items = items
        self.streamingTail = streamingTail
        self.error = error
        self.verbosity = verbosity
        self.onRetry = onRetry
        self.onContentTap = onContentTap
    }

    @Environment(\.superTheme) private var theme
    @State private var scrollPosition = ScrollPosition()
    @State private var contentGeometry = ContentGeometry()
    /// Captured in `.onChange(of: verbosity)` and consumed on the next
    /// geometry tick — i.e. once the blocks have finished expanding or
    /// collapsing and the new content height is in. Splitting capture and
    /// apply across two ticks lets us scroll against the post-relayout
    /// geometry instead of the stale pre-change one.
    @State private var pendingVerbosityScrollIntent: VerbosityScrollIntent?

    /// One-shot latch for scroll-to-bottom on the first valid geometry
    /// tick. Re-arms whenever SwiftUI rebuilds the view — `@State`
    /// discards on view-identity changes — so every fresh mount with
    /// overflowing content anchors at the latest message.
    @State private var didApplyInitialBottomAnchor = false

    /// What to do with the scroll position immediately after a verbosity
    /// change settles. Expansion keeps the user anchored to the same chat
    /// region; collapse jumps to the latest message because the
    /// pre-collapse viewport bottom usually sat inside a now-collapsed
    /// block, making any preserved distance visually arbitrary.
    private enum VerbosityScrollIntent: Equatable {
        case preserveDistance(CGFloat)
        case scrollToBottom
    }

    /// Snapshot of the scroll viewport + content sizes captured every time
    /// `onScrollGeometryChange` fires. We need all three values to compute
    /// `distanceFromBottom` and to restore a target offset after a layout
    /// shift triggered by a verbosity change.
    private struct ContentGeometry: Equatable {
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0
        var offsetY: CGFloat = 0

        /// Points between the bottom of the visible viewport and the bottom
        /// edge of the chat content. Zero means the user is pinned to the
        /// latest message.
        var distanceFromBottom: CGFloat {
            max(0, contentHeight - offsetY - viewportHeight)
        }
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    row(for: item).id(item.id)
                }
                if let tail = streamingTail {
                    StreamingTail(tail: tail, verbosity: verbosity).id("__streaming_tail")
                }
                if let banner = error {
                    ErrorBanner(banner: banner, onRetry: onRetry)
                        .padding(.vertical, 8)
                }
                Color.clear.frame(height: 4).id("__bottom")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { onContentTap() }
            )
        }
        .background(theme.background)
        // Drag-to-dismiss; the `simultaneousGesture` above handles
        // tap-to-dismiss. Both routes lead through `ChatScreen`'s
        // `dismissKeyboard()` via the `onContentTap` callback (taps) and
        // SwiftUI's native scroll-view keyboard handling (drags).
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ContentGeometry.self) { geo in
            ContentGeometry(
                contentHeight: geo.contentSize.height,
                viewportHeight: geo.containerSize.height,
                offsetY: geo.contentOffset.y
            )
        } action: { _, newGeo in
            contentGeometry = newGeo
            // First overflow tick after a fresh mount: anchor at the
            // bottom edge. The latch arms only after a successful scroll,
            // so a partial first-tick `contentHeight` (e.g. a `LazyVStack`
            // that hasn't laid out off-screen rows yet) doesn't strand
            // the view at the top — the next tick with a larger
            // `contentHeight` will scroll. Short chats whose content
            // always fits never latch and stay top-anchored (default).
            if !didApplyInitialBottomAnchor
                && newGeo.contentHeight > newGeo.viewportHeight
                && newGeo.viewportHeight > 0 {
                didApplyInitialBottomAnchor = true
                scrollPosition.scrollTo(edge: .bottom)
            }
            // First geometry tick after a verbosity flip: layout has now
            // settled at the new content height, so apply whichever scroll
            // intent the verbosity change recorded. Either anchors the
            // viewport so the user doesn't get dropped into the middle of
            // a re-laid-out block.
            if let intent = pendingVerbosityScrollIntent {
                pendingVerbosityScrollIntent = nil
                switch intent {
                case .preserveDistance(let saved):
                    let targetY = max(0, newGeo.contentHeight - newGeo.viewportHeight - saved)
                    scrollPosition.scrollTo(y: targetY)
                case .scrollToBottom:
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
        .onChange(of: verbosity) { oldValue, newValue in
            // Expansion: keep the user anchored to the same chat region so
            // they don't get dropped into the middle of a newly expanded
            // block. Collapse: snap to the latest message — the pre-collapse
            // bottom of the viewport was usually inside an expanded block,
            // so any preserved distance maps to a visually arbitrary spot
            // in the now-shorter chat (and can clamp to the top entirely
            // when the saved distance exceeds the new content height).
            if newValue.rank > oldValue.rank {
                pendingVerbosityScrollIntent = .preserveDistance(contentGeometry.distanceFromBottom)
            } else {
                pendingVerbosityScrollIntent = .scrollToBottom
            }
        }
        .onChange(of: items.count) { _, _ in
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: streamingTail) { _, _ in
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    @ViewBuilder
    private func row(for item: Item) -> some View {
        switch item {
        case .userBubble(_, let text):
            UserBubble(text: text)
        case .assistantText(_, let thinking, let thinkingDurationMs, let text, let toolCalls):
            AssistantMessage(
                thinking: thinking,
                thinkingDurationMs: thinkingDurationMs,
                text: text,
                toolCalls: toolCalls,
                verbosity: verbosity
            )
        case .compactionBanner(_, let summary):
            CompactionBanner(summary: summary)
        }
    }
}
