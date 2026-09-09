import SwiftUI

/// Pins the read-only system motion preference in previews and UI tests.
private struct MessageListReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var messageListReduceMotionOverride: Bool? {
        get { self[MessageListReduceMotionOverrideKey.self] }
        set { self[MessageListReduceMotionOverrideKey.self] = newValue }
    }
}

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
    /// Shows the non-interactive copy confirmation above transcript navigation.
    public let showCopyConfirmation: Bool

    public init(
        items: [Item],
        streamingTail: StreamingState? = nil,
        error: ErrorState? = nil,
        scrollRequest: ScrollRequest? = nil,
        interruptedResponse: StreamingState? = nil,
        showCopyConfirmation: Bool = false,
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
        self.showCopyConfirmation = showCopyConfirmation
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.messageListReduceMotionOverride) private var reduceMotionOverride
    @State private var focus = MessageListFocus()
    @State private var scrollMeasurementID = 0
    @State private var thinkingExpansion: [ThinkingKey: Bool] = [:]
    @State private var bottomScroll = BottomScrollState()
    @State private var bottomVisibility = ScrollToBottomButton.VisibilityState()

    private static let bottomID = "__transcript_bottom"

    /// The live response and its saved row share the same logical slot.
    struct ThinkingKey: Hashable {
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

    /// Geometry callbacks mutate the request without invalidating layout.
    private final class BottomScrollState {
        var request = MessageListBottomScrollRequest<BottomScrollContext>()
        var isNativeAnimating = false
    }

    /// Same-turn tokens and persistence keep the tap alive until rendered arrival.
    struct BottomScrollContext: Equatable {
        let turnID: String?
        let viewport: CGSize
        let verbosity: ChatVerbosity
        let thinkingExpansion: [ThinkingKey: Bool]
    }

    private struct BottomGeometry: Equatable {
        let bottomY: CGFloat
        let measurementID: Int
        let content: BottomScrollContext
    }

    public var body: some View {
        GeometryReader { geometry in
            transcript(containerSize: geometry.size)
        }
    }

    private func transcript(containerSize: CGSize) -> some View {
        let containerHeight = containerSize.height
        let turns = MessageListTurn.group(items)
        let bottomScrollContext = BottomScrollContext(
            turnID: turns.last?.id, viewport: containerSize,
            verbosity: verbosity, thinkingExpansion: thinkingExpansion
        )
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
                        .onGeometryChange(for: MessageListFocus.Geometry?.self) { [scrollMeasurementID] geometry in
                            guard let request = scrollRequest, request.messageID == turn.id else { return nil }
                            return MessageListFocus.Geometry(
                                request: request,
                                viewportY: geometry.frame(in: .named("transcript-viewport")).minY,
                                measurementID: scrollMeasurementID
                            )
                        } action: { geometry in
                            guard let geometry else { return }
                            perform(focus.measure(geometry), using: proxy)
                        }
                        .onGeometryChange(for: BottomGeometry?.self) { [scrollMeasurementID] geometry in
                            guard turn.id == turns.last?.id else { return nil }
                            return BottomGeometry(
                                bottomY: geometry.frame(in: .named("transcript-viewport")).maxY + 8,
                                measurementID: scrollMeasurementID, content: bottomScrollContext
                            )
                        } action: { geometry in
                            guard let geometry else { return }
                            if bottomScroll.request.shouldRefine(
                                distanceToBottom: geometry.bottomY - containerHeight,
                                isRendered: true, content: geometry.content, measurementID: geometry.measurementID
                            ) {
                                scrollToBottom(using: proxy)
                            }
                        }
                    }
                    if turns.isEmpty {
                        responseTail(turn: nil)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // Synchronous viewport input, never a geometry-to-state feedback
                // loop. The focused turn keeps its space even after a short reply.
                .frame(minHeight: containerHeight, alignment: .top)
                .id(Self.bottomID)
                .onGeometryChange(for: BottomGeometry.self) { [scrollMeasurementID] geometry in
                    BottomGeometry(
                        bottomY: geometry.frame(in: .named("transcript-viewport")).maxY,
                        measurementID: scrollMeasurementID, content: bottomScrollContext
                    )
                } action: { geometry in
                    // The stack can seek using estimates, but the rendered last
                    // turn above confirms arrival after lazy materialization.
                    if bottomScroll.request.shouldRefine(
                        distanceToBottom: geometry.bottomY - containerHeight,
                        isRendered: turns.isEmpty, content: geometry.content, measurementID: geometry.measurementID
                    ) {
                        scrollToBottom(using: proxy)
                    }
                }
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
            .onScrollGeometryChange(for: Bool.self) { geometry in
                ScrollToBottomButton.VisibilityState.isAwayFromBottom(geometry)
            } action: { _, isAway in
                bottomVisibility.isVisible = isAway
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if showCopyConfirmation {
                        CopyConfirmationPill()
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    // Retain this slot while the arrow fades or is hidden, so
                    // the confirmation never moves across its hit target.
                    ScrollToBottomButton(visibility: bottomVisibility) {
                        focus.cancel()
                        bottomScroll.request.begin(content: bottomScrollContext, animated: !reduceMotion)
                        scrollToBottom(using: proxy)
                    }
                }
                .padding(.bottom, ScrollToBottomButton.bottomPadding)
                .animation(.easeInOut(duration: 0.18), value: showCopyConfirmation)
            }
            .onChange(of: bottomScrollContext) { _, _ in
                bottomScroll.request.cancel()
            }
            .onChange(of: scrollRequest, initial: true) { previous, request in
                guard let request, turns.contains(where: { $0.id == request.messageID }) else { return }
                bottomScroll.request.cancel()
                // Mount restored history immediately; animate only new intent.
                perform(focus.begin(request, animated: previous != request && !reduceMotion), using: proxy)
            }
            .onScrollPhaseChange { previous, phase in
                bottomScroll.isNativeAnimating = phase == .animating
                if phase == .tracking || phase == .interacting || phase == .decelerating {
                    focus.cancel()
                    bottomScroll.request.cancel()
                } else if phase == .animating {
                    focus.motionBegan()
                    bottomScroll.request.motionBegan()
                } else if previous == .animating, phase == .idle {
                    let nextMeasurementID = scrollMeasurementID + 1
                    let focusEnded = focus.motionEnded(awaiting: nextMeasurementID)
                    let bottomEnded = bottomScroll.request.motionEnded(awaiting: nextMeasurementID)
                    if focusEnded || bottomEnded {
                        // One fresh measurement per completed move, even when
                        // the last animation frame's geometry callback is late.
                        scrollMeasurementID = nextMeasurementID
                    }
                }
            }
        }
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        let movementID = bottomScroll.request.movementID
        if bottomScroll.isNativeAnimating { bottomScroll.request.motionBegan() }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3), completionCriteria: .removed) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        } completion: {
            // A lazy target may produce no native motion. Reconcile that seek
            // without treating transaction completion as the end of real motion.
            let nextMeasurementID = scrollMeasurementID + 1
            if bottomScroll.request.animationCompleted(for: movementID, awaiting: nextMeasurementID) {
                scrollMeasurementID = nextMeasurementID
            }
        }
    }

    private func perform(_ move: MessageListFocus.Move?, using proxy: ScrollViewProxy) {
        guard let move else { return }
        // Native scroll phases report when this movement actually finishes;
        // withAnimation's completion can fire before a proxy scroll is done.
        withAnimation(move.animated ? .easeInOut(duration: 0.3) : nil) {
            proxy.scrollTo(move.request.messageID, anchor: .top)
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
