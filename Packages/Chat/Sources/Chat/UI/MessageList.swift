import Foundation
import SwiftUI

/// Scrollable transcript: persisted `MessageRecord`s laid out as user
/// bubbles + assistant text/tool blocks, with an optional live streaming
/// overlay tail showing the in-flight assistant text/thinking, and an
/// optional error banner above the composer.
///
/// Persisted assistant text, thinking traces, the compaction-banner
/// summary, *and* the live streaming tail all run through
/// ``MarkdownText`` (MarkdownUI + Splash). The streaming tail opts into
/// the partial-input mode (`treatAsPartial: true`) so an unterminated
/// fence/link/emphasis run renders cleanly while the closer is still in
/// flight. To keep the markdown reparse cost bounded under per-SSE-delta
/// arrival rates, `ChatScreenViewModel`'s coalescer flushes
/// `streamingTail.text` on whitespace boundaries (and at a 100ms ceiling
/// otherwise) — see `appendStreamingText(_:)`.
public struct MessageList: View {
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
            toolCalls: [ToolCallItem]
        )
        case compactionBanner(id: String, summary: String)

        public var id: String {
            switch self {
            case .userBubble(let id, _, _),
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
    /// Forwarded to every ``AssistantMessage`` so the Regenerate button
    /// dims and ignores taps during a turn. Kept at `MessageList`'s
    /// level (rather than reading the view model from each row) so the
    /// view tree stays parameter-driven and snapshot tests can pin
    /// either state without a live view model.
    public let isStreaming: Bool
    /// Fired with the tapped assistant message's text when the user
    /// taps Copy. ``ChatScreen`` writes to the pasteboard and flips the
    /// "Copied!" pill.
    public let onCopyTapped: (String) -> Void
    /// Fired with the tapped assistant message's id when the user taps
    /// Regenerate. ``ChatScreen`` stages a confirmation dialog before
    /// trimming the transcript.
    public let onRegenerateTapped: (String) -> Void

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
        onContentTap: @escaping () -> Void = {},
        isStreaming: Bool = false,
        onCopyTapped: @escaping (String) -> Void = { _ in },
        onRegenerateTapped: @escaping (String) -> Void = { _ in }
    ) {
        self.items = items
        self.streamingTail = streamingTail
        self.error = error
        self.verbosity = verbosity
        self.onRetry = onRetry
        self.onContentTap = onContentTap
        self.isStreaming = isStreaming
        self.onCopyTapped = onCopyTapped
        self.onRegenerateTapped = onRegenerateTapped
    }

    @Environment(\.superTheme) private var theme
    /// Programmatic scroll-position binding driven by the three
    /// pinpoint observers below: `.onChange(of: items.count)`,
    /// `.onChange(of: streamingTail?.text)`, and
    /// `.onScrollGeometryChange(for: ContainerSnapshot.self)`. The
    /// first two are value-based; the third is geometry-based but
    /// reads only `containerSize.height` plus a "was at bottom"
    /// boolean — never the live `contentOffset` — and gates its
    /// `scrollTo` call on a container-height delta. That keeps it
    /// out of the feedback loop the prior implementation hit:
    /// `scrollTo` mutates content offset, not container height, so
    /// it can't retrigger the action through its own writes.
    @State private var scrollPosition = ScrollPosition()
    /// Reduced snapshot of the scroll geometry — just the container
    /// height plus whether the user was within ``bottomFollowThreshold``
    /// of the bottom edge. Equatable so SwiftUI only fires the
    /// `onScrollGeometryChange` action on actual transitions.
    private struct ContainerSnapshot: Equatable {
        var height: CGFloat
        var isAtBottom: Bool
    }
    /// Distance from the bottom edge within which the user counts as
    /// "still at bottom" for the auto-follow gate. 8pt absorbs the
    /// LazyVStack lazy-materialization jitter that can leave the
    /// offset a row-thickness short of the true bottom for a layout
    /// pass or two, without pulling reading-history positions back
    /// down on every keyboard transition.
    private static let bottomFollowThreshold: CGFloat = 8

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
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            // 8pt of breathing room at the bottom — preserves the
            // visual margin the old `__bottom` clear-color marker
            // (4pt) used to add on top of the 4pt LazyVStack padding.
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { onContentTap() }
            )
        }
        .background(theme.background)
        // Drag-to-dismiss; the `simultaneousGesture` above handles
        // tap-to-dismiss. Both routes lead through `ChatScreen`'s
        // `dismissKeyboard()` via the `onContentTap` callback (taps) and
        // SwiftUI's native scroll-view keyboard handling (drags). When
        // the keyboard rises, the composer parked in `ChatScreen`'s
        // `safeAreaInset(edge: .bottom)` rides the safe area up;
        // SwiftUI's automatic keyboard avoidance is the canonical
        // mechanism the canonical iOS chat pattern relies on. Verified
        // on-device — synthetic harness doesn't faithfully simulate
        // the keyboard so the regression suite covers content/initial-
        // offset cases only.
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($scrollPosition)
        // Declarative anchor roles:
        //   - no-role `.defaultScrollAnchor(.bottom)` sets the initial
        //     position for a long, overflowing transcript — lands
        //     at the bottom on mount.
        //   - `.alignment` pinned to `.top` keeps non-scrollable short
        //     chats top-aligned, filling from the top with empty space
        //     below — like a fresh page. Without this override the
        //     `.bottom` anchor would push short content to the bottom
        //     of the viewport, which is the wrong shape for a
        //     fresh/empty chat.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
        // Bottom-pin on content grow (new message, lazy-mat'd row
        // becoming visible) and on streaming-text deltas. Empirically
        // `.defaultScrollAnchor(.bottom, for: .sizeChanges)` does not
        // honor content-size changes in iOS 26.4 / Xcode 26.4.1 — the
        // bottom slips by the height of newly-appended content. These
        // two `.onChange` handlers are the smallest reliable
        // replacement: value-based observers that fire once per
        // settled change (not per layout pass), so they cannot form
        // the geometry/scroll feedback loop the prior
        // `.onScrollGeometryChange` implementation did.
        .onChange(of: items.count) { _, _ in
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: streamingTail?.text) { _, _ in
            scrollPosition.scrollTo(edge: .bottom)
        }
        // Bottom-pin on container shrink/grow (the chat surface's
        // height changes when the keyboard rises/dismisses — see
        // `ChatOverlay`'s `keyboardAwareHeight`-capped frame). The
        // transform reads `containerSize.height` and a boolean
        // "isAtBottom"; the action fires `scrollTo(.bottom)` only on
        // a height change AND only when the user was already at the
        // bottom. Crucially, the action does **not** read live
        // `contentOffset`, so the `scrollTo` it issues can't retrigger
        // it via its own write — that was the feedback loop the
        // prior implementation hit during keyboard animations.
        .onScrollGeometryChange(for: ContainerSnapshot.self) { geo in
            let distance = max(0, geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height)
            return ContainerSnapshot(
                height: geo.containerSize.height,
                isAtBottom: distance < Self.bottomFollowThreshold
            )
        } action: { oldValue, newValue in
            guard oldValue.height != newValue.height else { return }
            guard oldValue.isAtBottom else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    @ViewBuilder
    private func row(for item: Item) -> some View {
        switch item {
        case .userBubble(_, let text, let references):
            UserBubble(text: text, references: references)
        case .assistantText(let id, let thinking, let thinkingDurationMs, let text, let toolCalls):
            AssistantMessage(
                thinking: thinking,
                thinkingDurationMs: thinkingDurationMs,
                text: text,
                toolCalls: toolCalls,
                verbosity: verbosity,
                isStreaming: isStreaming,
                onCopyTapped: { onCopyTapped(text) },
                onRegenerateRequested: { onRegenerateTapped(id) }
            )
        case .compactionBanner(_, let summary):
            CompactionBanner(summary: summary)
        }
    }
}
