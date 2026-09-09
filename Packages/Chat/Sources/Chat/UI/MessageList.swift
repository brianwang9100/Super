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
    public let streamingTail: StreamingState?
    public let error: ErrorState?
    public let verbosity: ChatVerbosity
    public let onRetry: () -> Void
    /// Attach inside scroll content because the ScrollView intercepts ancestor gestures.
    /// Run simultaneously so child actions also dismiss the keyboard.
    public let onContentTap: () -> Void
    public let isStreaming: Bool
    public let onCopyTapped: (String) -> Void
    public let onRegenerateTapped: (String) -> Void
    public let onConfirmSearch: (String) -> Void
    public let onSkipSearch: (String) -> Void

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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.messageListReduceMotionOverride) private var reduceMotionOverride
    @State private var focus = MessageListFocus()
    @State private var focusMeasurementID = 0
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
                        // Preserve parent and row identities so saved responses retain expanded thinking/tool state.
                        .frame(
                            minHeight: turn.id == scrollRequest?.messageID
                                ? max(0, containerHeight - 16) : 0,
                            alignment: .top
                        )
                        .id(turn.id)
                        .onGeometryChange(for: MessageListFocus.Geometry?.self) { [focusMeasurementID] geometry in
                            guard let request = scrollRequest, request.messageID == turn.id else { return nil }
                            return MessageListFocus.Geometry(
                                request: request,
                                viewportY: geometry.frame(in: .named("transcript-viewport")).minY,
                                measurementID: focusMeasurementID
                            )
                        } action: { geometry in
                            guard let geometry else { return }
                            perform(focus.measure(geometry), using: proxy)
                        }
                    }
                    if turns.isEmpty {
                        responseTail(turn: nil)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // Measure synchronously to avoid a geometry-to-state feedback loop.
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
            .onChange(of: scrollRequest, initial: true) { previous, request in
                guard let request, turns.contains(where: { $0.id == request.messageID }) else { return }
                // Mount restored history immediately; animate only new intent.
                perform(focus.begin(request, animated: previous != request && !reduceMotion), using: proxy)
            }
            .onScrollPhaseChange { previous, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating {
                    focus.cancel()
                } else if phase == .animating {
                    focus.motionBegan()
                } else if previous == .animating, phase == .idle {
                    let nextMeasurementID = focusMeasurementID + 1
                    if focus.motionEnded(awaiting: nextMeasurementID) {
                        // One fresh measurement per completed move, even when
                        // the last animation frame's geometry callback is late.
                        focusMeasurementID = nextMeasurementID
                    }
                }
            }
        }
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

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
