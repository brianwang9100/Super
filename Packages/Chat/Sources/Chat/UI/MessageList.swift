import SwiftUI

/// Transcript with stable turn containers. Explicit sends focus the user
/// message at the top; response updates never request a scroll.
public struct MessageList: View {
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
    /// Fired with the parked `request_web_search` tool-call id when the user
    /// approves the inline search prompt. Routed to the view model's
    /// `confirmSearch(id:)`.
    public let onConfirmSearch: (String) -> Void
    /// Fired with the parked tool-call id when the user declines the inline
    /// search prompt. Routed to the view model's `skipSearch(id:)`.
    public let onSkipSearch: (String) -> Void

    /// The most recent send, retry, or regenerate action; independent of tokens.
    public let scrollRequest: ScrollRequest?
    /// Unpersisted partial response retained after a stop or error.
    public let interruptedResponse: StreamingState?

    public init(
        items: [Item],
        streamingTail: StreamingState? = nil,
        error: ErrorState? = nil,
        scrollRequest: ScrollRequest? = nil,
        interruptedResponse: StreamingState? = nil,
        verbosity: ChatVerbosity = .simple,
        onRetry: @escaping () -> Void = {},
        onContentTap: @escaping () -> Void = {},
        isStreaming: Bool = false,
        onCopyTapped: @escaping (String) -> Void = { _ in },
        onRegenerateTapped: @escaping (String) -> Void = { _ in },
        onConfirmSearch: @escaping (String) -> Void = { _ in },
        onSkipSearch: @escaping (String) -> Void = { _ in }
    ) {
        self.items = items
        self.streamingTail = streamingTail
        self.error = error
        self.scrollRequest = scrollRequest
        self.interruptedResponse = interruptedResponse
        self.verbosity = verbosity
        self.onRetry = onRetry
        self.onContentTap = onContentTap
        self.isStreaming = isStreaming
        self.onCopyTapped = onCopyTapped
        self.onRegenerateTapped = onRegenerateTapped
        self.onConfirmSearch = onConfirmSearch
        self.onSkipSearch = onSkipSearch
    }

    @Environment(\.superTheme) private var theme
    @State private var focus = TurnFocus()
    @State private var thinkingExpansion: [ThinkingKey: Bool] = [:]

    /// The live response and its saved row share the same logical slot.
    private struct ThinkingKey: Hashable {
        let turnID: String
        let responseIndex: Int
    }

    private func expansion(for turn: MessageListTurn, before itemID: String? = nil) -> Binding<Bool> {
        let index = turn.items.prefix { $0.id != itemID }.filter {
            if case .assistantText = $0 { return true }
            return false
        }.count
        let key = ThinkingKey(turnID: turn.id, responseIndex: index)
        return Binding(
            get: { thinkingExpansion[key] ?? verbosity.atLeast(.thinking) },
            set: { thinkingExpansion[key] = $0 }
        )
    }

    /// A non-observable latch: geometry callbacks must not invalidate layout.
    private final class TurnFocus {
        var completed: ScrollRequest?
        var current: ScrollRequest?
        var attempts = 0
    }

    private struct TurnGeometry: Equatable {
        let request: ScrollRequest
        let viewportY: CGFloat
    }

    public var body: some View {
        GeometryReader { geometry in
            transcript(containerHeight: geometry.size.height)
        }
    }

    private func transcript(containerHeight: CGFloat) -> some View {
        let turns = MessageListTurn.group(items)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(turn.items) { item in
                                row(for: item, thinkingExpansion: expansion(for: turn, before: item.id))
                                    .accessibilityIdentifier("chat-message-\(item.id)")
                            }
                            if turn.id == turns.last?.id {
                                responseTail(turn: turn)
                            }
                        }
                        // Keep the same parent and row identities when a turn
                        // becomes history, preserving expanded thinking/tool state.
                        .frame(
                            minHeight: turn.id == scrollRequest?.messageID
                                ? max(0, containerHeight - 16) : 0,
                            alignment: .top
                        )
                        .id(turn.id)
                        .onGeometryChange(for: TurnGeometry?.self) { geometry in
                            guard let request = scrollRequest, request.messageID == turn.id else { return nil }
                            return TurnGeometry(
                                request: request,
                                viewportY: geometry.frame(in: .named("transcript-viewport")).minY
                            )
                        } action: { geometry in
                            guard let geometry, focus.completed != geometry.request else { return }
                            if focus.current != geometry.request {
                                focus.current = geometry.request
                                focus.attempts = 0
                            }
                            // ID seeks into lazy history can initially use estimated
                            // row heights. Refine only this explicit request against
                            // the materialized turn, then relinquish all ownership.
                            if abs(geometry.viewportY) <= 9 || focus.attempts >= 4 {
                                focus.completed = geometry.request
                                return
                            }
                            focus.attempts += 1
                            proxy.scrollTo(geometry.request.messageID, anchor: .top)
                        }
                    }
                    if turns.isEmpty {
                        responseTail(turn: nil)
                    }
                }
                .scrollTargetLayout(isEnabled: scrollRequest != nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // Synchronous viewport input, never a geometry-to-state feedback
                // loop. The focused turn keeps its space even after a short reply.
                .frame(minHeight: containerHeight, alignment: .top)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { onContentTap() })
            }
            .background(theme.background)
            .coordinateSpace(name: "transcript-viewport")
            .scrollDismissesKeyboard(.interactively)
            // Initial history position has no ongoing ownership. Size changes
            // preserve the leading reading edge; only a user action calls scrollTo.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .onChange(of: scrollRequest, initial: true) { _, request in
                guard let request, turns.contains(where: { $0.id == request.messageID }) else { return }
                if focus.completed != request {
                    proxy.scrollTo(request.messageID, anchor: .top)
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating {
                    focus.completed = scrollRequest
                }
            }
        }
    }

    @ViewBuilder
    private func responseTail(turn: MessageListTurn?) -> some View {
        if let tail = streamingTail ?? interruptedResponse {
            StreamingTail(
                tail: tail, verbosity: verbosity, isActive: streamingTail != nil,
                thinkingExpansion: turn.map { expansion(for: $0) }
            )
                .id("__streaming_tail")
        }
        if let banner = error {
            ErrorBanner(banner: banner, onRetry: onRetry)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func row(for item: Item, thinkingExpansion: Binding<Bool>) -> some View {
        switch item {
        case .userBubble(_, let text, let references):
            UserBubble(text: text, references: references)
        case .assistantText(let id, let thinking, let thinkingDurationMs, let text, let toolCalls, let sources, let searchSuggestionsHTML, let searchSystem, let searchQuery):
            AssistantMessage(
                thinking: thinking,
                thinkingDurationMs: thinkingDurationMs,
                text: text,
                toolCalls: toolCalls,
                sources: sources,
                searchSuggestionsHTML: searchSuggestionsHTML,
                searchSystem: searchSystem,
                searchQuery: searchQuery,
                verbosity: verbosity,
                isStreaming: isStreaming,
                onCopyTapped: { onCopyTapped(text) },
                onRegenerateRequested: { onRegenerateTapped(id) },
                onConfirmSearch: onConfirmSearch,
                onSkipSearch: onSkipSearch,
                thinkingExpansion: thinkingExpansion
            )
        case .compactionBanner(_, let summary):
            CompactionBanner(summary: summary)
        }
    }
}
