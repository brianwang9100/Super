import Foundation
import SwiftUI

/// Scrollable transcript: persisted `MessageRecord`s laid out as user
/// bubbles + assistant text/tool blocks, with an optional live streaming
/// overlay tail showing the in-flight assistant text/thinking, and an
/// optional error banner above the composer.
///
/// M7 renders assistant text as plain `Text` and tool/thinking blocks as
/// minimal placeholder cards — M10 swaps in MarkdownUI + Splash for
/// markdown/code/thinking polish without changing this view's contract.
public struct MessageListView: View {
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
            toolCalls: [ToolCallView]
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
    public struct ToolCallView: Identifiable, Sendable, Equatable {
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
    public let streamingTail: StreamingTail?
    /// Error banner shown above the composer; nil hides the banner.
    public let error: ErrorBanner?
    public let verbosity: ChatVerbosity
    public let onRetry: () -> Void

    public struct StreamingTail: Sendable, Equatable {
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

    public struct ErrorBanner: Sendable, Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    public init(
        items: [Item],
        streamingTail: StreamingTail? = nil,
        error: ErrorBanner? = nil,
        verbosity: ChatVerbosity = .simple,
        onRetry: @escaping () -> Void = {}
    ) {
        self.items = items
        self.streamingTail = streamingTail
        self.error = error
        self.verbosity = verbosity
        self.onRetry = onRetry
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
                    StreamingTailView(tail: tail, verbosity: verbosity).id("__streaming_tail")
                }
                if let banner = error {
                    ErrorBannerView(message: banner.message, onRetry: onRetry)
                        .padding(.vertical, 8)
                }
                Color.clear.frame(height: 4).id("__bottom")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .background(theme.background)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ContentGeometry.self) { geo in
            ContentGeometry(
                contentHeight: geo.contentSize.height,
                viewportHeight: geo.containerSize.height,
                offsetY: geo.contentOffset.y
            )
        } action: { _, newGeo in
            contentGeometry = newGeo
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
            UserBubbleView(text: text)
        case .assistantText(_, let thinking, let thinkingDurationMs, let text, let toolCalls):
            AssistantMessageView(
                thinking: thinking,
                thinkingDurationMs: thinkingDurationMs,
                text: text,
                toolCalls: toolCalls,
                verbosity: verbosity
            )
        case .compactionBanner(_, let summary):
            CompactionBannerView(summary: summary)
        }
    }
}

// MARK: - User bubble

struct UserBubbleView: View {
    let text: String
    @Environment(\.superTheme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(.subheadline))
                .lineSpacing(2)
                .foregroundStyle(theme.bubbleInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    UnevenRoundedRectangle(
                        cornerRadii: .init(
                            topLeading: 18,
                            bottomLeading: 18,
                            bottomTrailing: 6,
                            topTrailing: 18
                        ),
                        style: .continuous
                    ).fill(theme.bubbleUser)
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Assistant message

struct AssistantMessageView: View {
    let thinking: String?
    let thinkingDurationMs: Int?
    let text: String
    let toolCalls: [MessageListView.ToolCallView]
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme

    var body: some View {
        // Some providers emit a stray newline or single space alongside a
        // tool call, so `text.isEmpty` would return false even though
        // there's nothing to show. Trim before gating so tool-call-only
        // turns reliably hide the body text + action row.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if let thinking, !thinking.isEmpty {
                ThinkingBlockView(
                    text: thinking,
                    durationSource: .finished(durationMs: thinkingDurationMs),
                    verbosity: verbosity
                )
            }
            ForEach(toolCalls) { call in
                ToolCallBlockView(call: call, verbosity: verbosity)
            }
            if hasText {
                Text(text)
                    .font(.system(.subheadline))
                    .lineSpacing(2)
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Copy + Regenerate only attach to a row that actually has
                // text — for tool-call-only or thinking-only turns there's
                // nothing to copy and the next turn carries the real reply,
                // so the action row would just be visual noise.
                HStack(spacing: 4) {
                    MessageActionButton(systemName: "doc.on.doc", label: "Copy") {
                        UIPasteboardClient.copy(text)
                    }
                    MessageActionButton(systemName: "arrow.clockwise", label: "Regenerate") {
                        // M12 wires this; the button is visible per the design
                        // but not yet functional in the MVP.
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct MessageActionButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @Environment(\.superTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(.caption))
                .foregroundStyle(theme.inkFaint)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Tool call (M7 placeholder; M10 polishes)

struct ToolCallBlockView: View {
    let call: MessageListView.ToolCallView
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme
    @State private var isExpanded: Bool

    init(call: MessageListView.ToolCallView, verbosity: ChatVerbosity) {
        self.call = call
        self.verbosity = verbosity
        self._isExpanded = State(initialValue: Self.shouldExpand(for: verbosity))
    }

    /// Tool blocks are heavyweight (parameters + result), so only the
    /// `.verbose` setting opens them by default. `.simple` and `.thinking`
    /// keep them collapsed behind the header pill.
    static func shouldExpand(for verbosity: ChatVerbosity) -> Bool {
        verbosity == .verbose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(.caption))
                        .foregroundStyle(theme.inkSoft)
                    Text(call.toolName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.ink)
                    statusBadge
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(.caption2).weight(.semibold))
                        .foregroundStyle(theme.inkFaint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("INPUT")
                    monospaceBlock(call.parametersJSON)
                    if let result = call.resultText {
                        sectionLabel("RESULT")
                        monospaceBlock(result)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.backgroundSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.borderFaint, lineWidth: 1)
        )
        // Verbosity changes broadcast a new default expansion state to every
        // block. Individual taps after that still win until the next switch.
        .onChange(of: verbosity) { _, newValue in
            isExpanded = Self.shouldExpand(for: newValue)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("running")
                    .font(.system(.caption))
                    .foregroundStyle(theme.inkFaint)
            }
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(.caption2).weight(.bold))
                    .foregroundStyle(theme.accent)
                Text("done")
                    .font(.system(.caption2))
                    .foregroundStyle(theme.accent)
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(theme.errorAccent)
                Text("failed")
                    .font(.system(.caption2))
                    .foregroundStyle(theme.errorAccent)
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2).weight(.medium))
            .tracking(0.5)
            .foregroundStyle(theme.inkFaint)
    }

    @ViewBuilder
    private func monospaceBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.inkSoft)
                .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.background)
        )
    }
}

// MARK: - Compaction banner (M7 minimal; M10 expands)

struct CompactionBannerView: View {
    let summary: String
    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                line
                Text("COMPACTED")
                    .font(.system(.caption2).weight(.medium))
                    .tracking(0.6)
                    .foregroundStyle(theme.inkFaint)
                line
            }
            Text(summary)
                .font(.system(.caption))
                .foregroundStyle(theme.inkSoft)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.backgroundSunken)
                )
        }
        .padding(.vertical, 8)
    }

    private var line: some View {
        Rectangle()
            .fill(theme.borderFaint)
            .frame(height: 1)
    }
}

// MARK: - Streaming tail

struct StreamingTailView: View {
    let tail: MessageListView.StreamingTail
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme

    /// The spark spins for the entire duration of the turn so the user
    /// always has a "still working" cue — both before the first delta
    /// (where there's nothing else on screen) and during text streaming
    /// (where the typing caret signals the active line, but the spark
    /// signals the overall turn isn't done yet). Suppressed during
    /// compaction so we don't double up with the "Compacting…" row's
    /// own progress indicator.
    private var showsWaitingSpark: Bool {
        !tail.isCompacting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tail.isCompacting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Compacting…")
                        .font(.system(.caption))
                        .foregroundStyle(theme.inkFaint)
                }
                .padding(.vertical, 6)
            }
            if !tail.thinking.isEmpty {
                ThinkingBlockView(
                    text: tail.thinking,
                    durationSource: .live(startedAt: tail.thinkingStartedAt ?? Date()),
                    verbosity: verbosity
                )
            }
            if !tail.text.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(tail.text)
                        .font(.system(.subheadline))
                        .lineSpacing(2)
                        .foregroundStyle(theme.ink)
                    TypingCaret()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsWaitingSpark {
                WaitingSparkView()
            }
        }
        .padding(.vertical, 2)
    }
}

/// Small spinning spark shown while the assistant is "thinking" but
/// hasn't streamed any text yet. Rotates linearly so the user has a
/// clear "still working" cue during the gap between submit and first
/// delta. Reduce Motion swaps the rotation for a static accent-colored
/// spark — the icon still communicates "we're processing" without the
/// continuous spin.
private struct WaitingSparkView: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        SparkIcon(size: 22, color: theme.accent)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .accessibilityLabel("Thinking")
            .padding(.vertical, 4)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

struct ThinkingBlockView: View {
    let text: String
    let durationSource: DurationSource
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme
    @State private var isExpanded: Bool

    /// Two distinct duration sources: `.live` ticks against the wall clock
    /// while the assistant is still thinking, `.finished` shows a static
    /// label backed by the persisted millisecond count.
    enum DurationSource: Equatable {
        case live(startedAt: Date)
        case finished(durationMs: Int?)
    }

    /// `.simple` collapses the body so the user just sees a "Thought for
    /// Xs" pill they can tap to inspect; `.thinking` and `.verbose` open
    /// expanded so the trace is visible without an extra tap.
    init(text: String, durationSource: DurationSource, verbosity: ChatVerbosity) {
        self.text = text
        self.durationSource = durationSource
        self.verbosity = verbosity
        self._isExpanded = State(initialValue: Self.shouldExpand(for: verbosity))
    }

    /// `.simple` keeps the body collapsed; `.thinking` and `.verbose` open
    /// it. Centralized so init and the verbosity-change observer agree.
    static func shouldExpand(for verbosity: ChatVerbosity) -> Bool {
        verbosity.atLeast(.thinking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded, !text.isEmpty {
                Text(text)
                    .font(.system(.footnote).italic())
                    .lineSpacing(2)
                    .foregroundStyle(theme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.backgroundSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.borderFaint, lineWidth: 1)
        )
        // Verbosity changes broadcast a new default expansion state to every
        // block. Individual taps after that still win until the next switch.
        .onChange(of: verbosity) { _, newValue in
            isExpanded = Self.shouldExpand(for: newValue)
        }
    }

    @ViewBuilder
    private var header: some View {
        switch durationSource {
        case .live(let startedAt):
            // 1Hz timeline so the second counter ticks while the model is
            // still thinking. The view stays cheap — only the label inside
            // the timeline re-renders.
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                headerButton(label: Self.label(forSeconds: Int(elapsed.rounded(.down))))
            }
        case .finished(let durationMs):
            headerButton(label: Self.label(forDurationMs: durationMs))
        }
    }

    @ViewBuilder
    private func headerButton(label: String) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(.caption))
                    .foregroundStyle(theme.inkSoft)
                Text(label)
                    .font(.system(.footnote).weight(.medium))
                    .foregroundStyle(theme.inkSoft)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(.caption2).weight(.semibold))
                    .foregroundStyle(theme.inkFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Thought for Xs" using the live elapsed second count. The first
    /// second is rendered as "0s" so the label appears the instant a
    /// thinking delta arrives — same convention every major chat UI uses.
    static func label(forSeconds seconds: Int) -> String {
        "Thought for \(max(0, seconds))s"
    }

    /// Persisted-row variant: rounds the millisecond count to seconds and
    /// falls back to the bare "Thinking" label when no duration was
    /// recorded (legacy rows from before the column existed).
    static func label(forDurationMs durationMs: Int?) -> String {
        guard let ms = durationMs else { return "Thinking" }
        let seconds = Int((Double(ms) / 1000.0).rounded())
        return label(forSeconds: seconds)
    }
}

/// 7×14pt accent caret. Animated blink suspended when Reduce Motion is on
/// (per AGENTS.md §Testing "Reduce Motion on/off"); the caret stays solid
/// in that case so the streaming surface still indicates activity.
struct TypingCaret: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible: Bool = true

    var body: some View {
        Capsule(style: .continuous)
            .fill(theme.accent)
            .frame(width: 7, height: 14)
            .padding(.leading, 2)
            .offset(y: 2)
            .opacity(visible ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Error banner

struct ErrorBannerView: View {
    let message: String
    let onRetry: () -> Void
    @Environment(\.superTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(.footnote))
                .foregroundStyle(theme.errorInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRetry) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(.caption2).weight(.semibold))
                    Text("Retry")
                        .font(.system(.caption).weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.errorAccent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.errorBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.errorBorder, lineWidth: 1)
        )
    }
}

// MARK: - Pasteboard

/// Tiny indirection so non-iOS test bodies don't drag in `UIKit`. Inside
/// the Chat package we know we're on iOS 18+; this just keeps the test
/// target free of UIKit-specific code paths if a future host expands.
enum UIPasteboardClient {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
