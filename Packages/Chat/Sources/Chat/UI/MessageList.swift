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

    public init(
        items: [Item],
        streamingTail: StreamingState? = nil,
        error: ErrorState? = nil,
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

    // MARK: - Scroll state
    //
    // Four pinpoint observers drive `scrollPosition`:
    //   1. `.onChange(of: items.count)` — unconditional bottom-snap
    //      (a new item is always a user-initiated event).
    //   2. `.onChange(of: streamingTail)` — gated on `wasAtBottom`
    //      so reading-history isn't yanked on every coalesced delta.
    //   3. `.onChange(of: verbosity)` — captures `verbosityScrollMode`
    //      against `latestSnapshot`, re-applied on every content-grow
    //      tick during the relayout.
    //   4. `.onScrollGeometryChange` — latches `wasAtBottom` and
    //      `latestSnapshot` from a `ContainerSnapshot` and consumes
    //      the verbosity mode; the action **never** reads live
    //      `contentOffset` for scroll-direction logic, so a
    //      `scrollTo` write can't retrigger the action through itself
    //      — that was the feedback loop the prior implementation hit
    //      during keyboard animations.

    /// Programmatic scroll-position binding; the observers below
    /// mutate it via `scrollTo` and never via direct assignment.
    @State private var scrollPosition = ScrollPosition()
    /// `true` when the most recent settled (content-stable) geometry
    /// tick saw the user within ``bottomFollowThreshold`` of the bottom.
    /// Initialized `false` so a mount with an in-flight stream
    /// doesn't fire a spurious auto-follow before the first tick.
    @State private var wasAtBottom = false
    /// Latest `ContainerSnapshot`; read by `.onChange(of: verbosity)`
    /// to capture pre-relayout distance-from-bottom.
    @State private var latestSnapshot: ContainerSnapshot?
    /// Active verbosity-driven scroll-restoration mode, set on a
    /// verbosity flip and cleared after
    /// ``verbosityStableTicksToClear`` consecutive content-stable
    /// ticks (handles `LazyVStack`'s occasional `contentHeight`
    /// over-then-under settling pattern).
    @State private var verbosityScrollMode: VerbosityScrollMode?
    /// Counter consumed by the geometry action; resets to 0 on every
    /// content-height change while ``verbosityScrollMode`` is active.
    @State private var verbosityStableTickCount: Int = 0
    /// Armed by `.onChange(of: items.count)` so the geometry action
    /// re-issues a bottom-snap once content height *settles* — the
    /// single immediate snap there lands against transient stream-end
    /// geometry (small semi container + large keyboard/composer inset +
    /// mid-flight markdown/keyboard animation), which the still-changing
    /// content height then invalidates, hiding the last rows. Mirrors the
    /// ``verbosityScrollMode`` settle pattern.
    @State private var pendingBottomSnap = false
    /// Counter for ``pendingBottomSnap``; resets to 0 on every content-
    /// height change and disarms the pending snap after
    /// ``bottomSnapStableTicksToClear`` consecutive content-stable ticks.
    @State private var bottomSnapStableTickCount = 0

    /// What to do with the scroll position while a verbosity-driven
    /// relayout is in flight. See ``verbosityScrollMode``.
    private enum VerbosityScrollMode: Equatable {
        case preserveDistance(CGFloat)
        case scrollToBottom
    }

    /// Number of consecutive content-height-stable ticks required to
    /// clear ``verbosityScrollMode``. Three covers the typical
    /// `LazyVStack` settle (a scrollTo-driven offset tick followed by
    /// a couple of no-op ticks once the row pass finishes) without
    /// holding the mode through a subsequent independent content
    /// change.
    private static let verbosityStableTicksToClear: Int = 3
    /// Consecutive content-height-stable ticks required to disarm
    /// ``pendingBottomSnap``. Independent of
    /// ``verbosityStableTicksToClear`` (same value today, different
    /// concern — the stream-end settle vs. the verbosity-relayout settle)
    /// so tuning one doesn't silently move the other.
    private static let bottomSnapStableTicksToClear: Int = 3
    /// Reduced, `Equatable` snapshot of the scroll geometry — the
    /// only shape `onScrollGeometryChange`'s transform emits.
    /// `contentHeight` lets the action distinguish content-grow ticks
    /// from user-scroll ticks; `offsetY` exposes the current scroll
    /// position to `.onChange(of: verbosity)` for the
    /// preserve-distance capture.
    private struct ContainerSnapshot: Equatable {
        /// `containerSize.height` of the `ScrollView` at the moment the
        /// snapshot was taken. Changes when the chat-surface frame
        /// shrinks/grows (keyboard show/dismiss).
        var height: CGFloat
        /// `contentSize.height` of the `ScrollView`. Grows when items
        /// are appended or the streaming tail's text/thinking grows,
        /// or when a verbosity flip expands inline blocks.
        var contentHeight: CGFloat
        /// `contentOffset.y` of the `ScrollView`. Latched here only so
        /// `.onChange(of: verbosity)` can compute the pre-relayout
        /// distance-from-bottom; the geometry action does *not* read
        /// this field for its own logic (that would re-introduce the
        /// feedback loop the refactor closed).
        var offsetY: CGFloat
        /// `true` when the snapshot's distance-from-bottom was within
        /// ``bottomFollowThreshold``. Captured from the geometry
        /// transform; not the live "is the user at the bottom right
        /// now" value — the latter is only knowable inside the next
        /// geometry tick.
        var isAtBottom: Bool

        /// Points between the bottom of the visible viewport and the
        /// bottom edge of the content at the moment this snapshot
        /// was taken. Used by the verbosity-expand intent to
        /// preserve the user's chat-region position across the
        /// relayout.
        var distanceFromBottom: CGFloat {
            max(0, contentHeight - offsetY - height)
        }
    }
    /// Distance from the bottom edge within which the user counts as
    /// "still at bottom" for the auto-follow gate. 8pt absorbs the
    /// LazyVStack lazy-materialization jitter that can leave the
    /// offset a row-thickness short of the true bottom for a layout
    /// pass or two, without pulling reading-history positions back
    /// down on every keyboard transition.
    private static let bottomFollowThreshold: CGFloat = 8

    public var body: some View {
        // Read the container height *synchronously* from a wrapping
        // `GeometryReader` and feed it straight into the content's
        // `minHeight` (see `transcriptScroll`). Crucially NOT via a
        // `GeometryReader → @State → layout` round-trip: that reintroduced
        // the keyboard-animation feedback hang (focusing the composer in
        // semi-expanded animates the surface height every frame for ~0.25s,
        // and a per-frame `@State` write + re-layout closed the loop).
        // `geo.size.height` is a one-directional input (the surface-imposed
        // frame); the content's `minHeight` can't change it, so there is no
        // feedback path.
        GeometryReader { geo in
            transcriptScroll(containerHeight: geo.size.height)
        }
    }

    private func transcriptScroll(containerHeight: CGFloat) -> some View {
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
            // Floor the content frame at the container height so it's
            // `max(containerHeight, contentHeight)` — continuous in the
            // container height with no fits-vs-overflows boundary. Short
            // content top-aligns within the filled frame (the fresh-page
            // shape, replacing the old `.defaultScrollAnchor(.top, for:
            // .alignment)`); long content makes the floor inert and scrolls
            // normally. This removes the bistable top/bottom anchor flip
            // that jittered while the surface was being actively resized
            // (drag/morph sweeping the container height through the content
            // height). `containerHeight` is `body`'s wrapping `GeometryReader`
            // height — a synchronous input from the surface frame, read
            // without any `@State`, so it can't feed a layout loop.
            .frame(minHeight: containerHeight, alignment: .top)
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
        // `.defaultScrollAnchor(.bottom)` sets the initial position for a
        // long, overflowing transcript — lands at the bottom on mount.
        // Short content is top-aligned by the `.frame(minHeight:)` floor on
        // the content above (not a `.defaultScrollAnchor(.top, for:
        // .alignment)`): the alignment-role anchor made the layout bistable
        // on `sign(contentHeight - containerHeight)` and flipped — jittering
        // — whenever an active resize swept the container across the content
        // height. The min-height floor is the continuous replacement.
        .defaultScrollAnchor(.bottom)
        // Bottom-pin on content grow (new message, lazy-mat'd row
        // becoming visible) and on streaming-content deltas.
        // Empirically `.defaultScrollAnchor(.bottom, for: .sizeChanges)`
        // does not honor content-size changes in iOS 26.4 / Xcode
        // 26.4.1 — the bottom slips by the height of newly-appended
        // content. These `.onChange` handlers are the smallest
        // reliable replacement: value-based observers that fire once
        // per settled change (not per layout pass), so they cannot
        // form the geometry/scroll feedback loop the prior
        // `.onScrollGeometryChange` implementation did.
        .onChange(of: items.count) { _, _ in
            // A new item is the user's most-recent action (send,
            // regenerate accept, stream-persist). Clear any
            // in-flight verbosity scroll mode first so the
            // content-grow tick that follows doesn't re-apply the
            // preserve-distance intent and yank the user back from
            // the bottom we're about to scroll them to.
            verbosityScrollMode = nil
            verbosityStableTickCount = 0
            scrollPosition.scrollTo(edge: .bottom)
            // Arm a settle re-snap: the immediate snap above lands against
            // transient geometry at stream end (the streaming tail just
            // cleared while the persisted row grew, and in semi-expanded +
            // keyboard the container is small with a large composer/keyboard
            // inset and the keyboard-glide animation may still be settling),
            // so the bottom it computes is invalidated as content height
            // keeps changing — leaving the last rows hidden behind the inset
            // until the user scrolls. The geometry action re-snaps once
            // content height holds steady (see `pendingBottomSnap`).
            pendingBottomSnap = true
            bottomSnapStableTickCount = 0
        }
        // `streamingTail` is the whole `StreamingState`, not just
        // `.text` — the tail grows during the pure-thinking phase via
        // `.thinking` *before* `.text` has any content, and observing
        // only `.text` misses that growth (the user would see the
        // thinking trace push the streaming bubble down out of view).
        // Gated on `wasAtBottom` so a user reading history during a
        // long response isn't yanked down on every coalesced delta.
        .onChange(of: streamingTail) { _, _ in
            guard wasAtBottom else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
        // Verbosity flip relayouts every on-screen `ThinkingBlock` /
        // `ToolCallBlock` and can grow content by hundreds of points.
        // Capture the *intent* here (against the most recent settled
        // snapshot) and consume it on the next geometry tick once the
        // relayout has measured, so the scroll math runs against
        // post-relayout `contentHeight`. Expanding preserves the
        // user's distance-from-bottom (they stay on the same chat
        // region); collapsing snaps to bottom because the
        // pre-collapse viewport bottom typically sat *inside* a
        // now-collapsed block, making any preserved distance map to
        // a visually arbitrary spot.
        .onChange(of: verbosity) { oldValue, newValue in
            if newValue.rank > oldValue.rank {
                // Fall back to `.scrollToBottom` when `latestSnapshot`
                // hasn't been captured yet (verbosity toggled before
                // the first geometry tick fired). A guaranteed
                // bottom-snap is better than the silent positional
                // jump that would result from setting no mode.
                verbosityScrollMode = latestSnapshot
                    .map { .preserveDistance($0.distanceFromBottom) }
                    ?? .scrollToBottom
            } else if newValue.rank < oldValue.rank {
                verbosityScrollMode = .scrollToBottom
            } else {
                return
            }
            verbosityStableTickCount = 0
        }
        // Bottom-pin on container shrink/grow (the chat surface's
        // height changes when the keyboard rises/dismisses — see
        // `ChatOverlay`'s `keyboardAwareHeight`-capped frame). The
        // transform reads `containerSize.height`, `contentSize.height`,
        // `contentOffset.y`, and a boolean "isAtBottom"; the action
        // fires `scrollTo(.bottom)` only on a height change AND only
        // when the live `wasAtBottom` latch is true. The action also
        // (1) latches `wasAtBottom` for the streaming/verbosity
        // observers — but **only** when the tick was a pure user
        // scroll (no content grow), because content-grow ticks fire
        // *after* those observers need the pre-grow status — and
        // (2) re-applies `verbosityScrollMode` on every content-height
        // change while it's active. Crucially, the action does **not** read
        // live `contentOffset` for its own scroll-direction logic
        // (only latches it into the snapshot), so the `scrollTo` it
        // issues can't retrigger it through its own writes — that
        // was the feedback loop the prior implementation hit during
        // keyboard animations.
        .onScrollGeometryChange(for: ContainerSnapshot.self) { geo in
            let distance = max(0, geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height)
            return ContainerSnapshot(
                height: geo.containerSize.height,
                contentHeight: geo.contentSize.height,
                offsetY: geo.contentOffset.y,
                isAtBottom: distance < Self.bottomFollowThreshold
            )
        } action: { oldValue, newValue in
            latestSnapshot = newValue
            // Latch the bottom-status only when this tick wasn't a
            // content-grow event. Content-grow flips `isAtBottom`
            // false (the bottom is suddenly further away) *before*
            // the gated `.onChange` observers run; we want them to
            // see the pre-grow status.
            if oldValue.contentHeight == newValue.contentHeight {
                wasAtBottom = newValue.isAtBottom
            }
            // Apply the verbosity scroll mode on every content-height
            // change while it's active. `LazyVStack` materializes
            // rows incrementally across several ticks (and can refine
            // `contentHeight` downward in a final tick), so
            // re-applying on each change keeps the offset locked to
            // the current-tick-correct target. The mode auto-clears
            // after ``verbosityStableTicksToClear`` consecutive
            // content-height-stable ticks.
            if let mode = verbosityScrollMode {
                if oldValue.contentHeight != newValue.contentHeight {
                    verbosityStableTickCount = 0
                    switch mode {
                    case .scrollToBottom:
                        scrollPosition.scrollTo(edge: .bottom)
                    case .preserveDistance(let savedDistance):
                        let targetY = max(0, newValue.contentHeight - newValue.height - savedDistance)
                        scrollPosition.scrollTo(y: targetY)
                    }
                } else {
                    verbosityStableTickCount += 1
                    if verbosityStableTickCount >= Self.verbosityStableTicksToClear {
                        verbosityScrollMode = nil
                        verbosityStableTickCount = 0
                    }
                }
            }
            // Stream-end settle re-snap. The immediate `scrollTo(.bottom)`
            // in `.onChange(of: items.count)` runs against transient
            // geometry (tail-clear + persisted-row-grow + keyboard/composer
            // inset + in-flight animation); re-snap on every content-height
            // change until it holds steady, so the final snap lands against
            // settled geometry. Gated on content-height equality (never live
            // `contentOffset`), so the `scrollTo` write can't retrigger it;
            // the stable-tick counter self-terminates once geometry stops
            // moving. Must sit *before* the container-height auto-follow's
            // early returns below, because the stream-end settle is mostly
            // content-only ticks (container height unchanged) that those
            // returns would skip. (For short content the `minHeight` floor
            // ties contentHeight to containerHeight, so a container resize
            // also re-fires this — harmless: re-snapping on a resize is
            // wanted, and it still disarms when motion stops.)
            if pendingBottomSnap {
                if oldValue.contentHeight != newValue.contentHeight {
                    bottomSnapStableTickCount = 0
                    scrollPosition.scrollTo(edge: .bottom)
                } else {
                    bottomSnapStableTickCount += 1
                    if bottomSnapStableTickCount >= Self.bottomSnapStableTicksToClear {
                        pendingBottomSnap = false
                        bottomSnapStableTickCount = 0
                    }
                }
            }
            // Past-end guard. The bottom-pin observers (`items.count`,
            // `streamingTail`, `pendingBottomSnap`, `verbosity`) each set the
            // offset against *one* tick's geometry. `LazyVStack` reports
            // `contentHeight` unstably — it flip-flops between two values on
            // alternating layout passes (observed swings up to ~1100pt during
            // the keyboard glide). When `contentHeight` collapses to its
            // smaller alternate *after* a bottom-pin computed against the larger
            // one — or when a drag/keyboard resize shrinks the viewport faster
            // than the offset re-pins — the offset is left below the content's
            // end and the small keyboard-up viewport renders blank past it: the
            // transient content-disappears flicker. Detect that geometrically
            // (offset past `contentHeight - height`) and re-pin to the bottom.
            // Sits before the auto-follow's early returns below because the
            // strand appears on content-only ticks the auto-follow would skip.
            //
            // Only correct on a tick where the container OR content height
            // actually changed — never on an offset-only tick. A user flicking
            // the transcript into the bottom edge rubber-bands `offset` past the
            // max with the geometry held constant; gating on a geometry change
            // leaves that legitimate overscroll bounce alone (it would otherwise
            // be cut short by a snap), while still catching every real strand —
            // those always coincide with a content-height collapse or a viewport
            // resize. On-device the live strands fired on resize ticks (the
            // container shrinking under a stale pin during a drag), which a
            // content-height-only gate would have wrongly suppressed.
            //
            // Loop-safe: this reads the offset only to test the static
            // invariant `offset <= contentHeight - height` and snaps to that
            // boundary — it does *not* infer scroll direction from the offset
            // (the feedback loop the geometry action otherwise avoids). It is
            // self-disarming: after the snap the offset sits at the boundary,
            // so the strand predicate is false next tick and it does not
            // re-fire. It can only move the offset *up* into the valid range,
            // never past an edge, and never affects a user scrolled up reading
            // history (they sit above the max offset, never past the end).
            let geometryChanged = oldValue.height != newValue.height
                || oldValue.contentHeight != newValue.contentHeight
            if geometryChanged, strandedPastEndOffset(
                content: newValue.contentHeight,
                container: newValue.height,
                offset: newValue.offsetY
            ) != nil {
                scrollPosition.scrollTo(edge: .bottom)
            }
            // Container-height-driven auto-follow (keyboard show/
            // dismiss). Guard on the live `wasAtBottom` latch rather
            // than `oldValue.isAtBottom`: a prior content-grow tick
            // may have flipped `oldValue.isAtBottom` false even
            // though the user was watching the bottom the whole time.
            guard oldValue.height != newValue.height else { return }
            guard wasAtBottom else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    @ViewBuilder
    private func row(for item: Item) -> some View {
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
                onSkipSearch: onSkipSearch
            )
        case .compactionBanner(_, let summary):
            CompactionBanner(summary: summary)
        }
    }
}

/// The offset to re-pin to when the scroll position is stranded *past the end*
/// of the content — i.e. the latched `offset` sits below the last point the
/// viewport can show, leaving a blank region. Returns `nil` when the offset is
/// within the valid `[0, content - container]` range (no correction needed).
///
/// Pulled out as a free function so the past-end guard's arithmetic is unit
/// testable without a live `ScrollPosition`. `epsilon` absorbs the sub-pixel
/// `LazyVStack` jitter that routinely leaves the offset a fraction past the max
/// without any visible void; only a real strand (a multi-point content-height
/// collapse after a bottom-pin) trips it.
func strandedPastEndOffset(
    content: CGFloat,
    container: CGFloat,
    offset: CGFloat,
    epsilon: CGFloat = 4
) -> CGFloat? {
    let maxOffset = max(0, content - container)
    guard offset > maxOffset + epsilon else { return nil }
    return maxOffset
}
