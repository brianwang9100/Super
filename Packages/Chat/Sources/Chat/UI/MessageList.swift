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
    //      against `latestSnapshotBox`, re-applied on every content-grow
    //      tick during the relayout.
    //   4. `.onScrollGeometryChange` — latches `wasAtBottom` and
    //      `latestSnapshotBox` from a `ContainerSnapshot` and consumes
    //      the verbosity mode; the action **never** reads live
    //      `contentOffset` for scroll-direction logic, so a
    //      `scrollTo` write can't retrigger the action through itself
    //      — that was the feedback loop the prior implementation hit
    //      during keyboard animations.

    /// Programmatic scroll-position binding; the observers below
    /// mutate it via `scrollTo` and never via direct assignment.
    ///
    /// Initialized to `edge: .bottom` so a long transcript mounts at its
    /// latest message. This is the replacement for the removed
    /// `.defaultScrollAnchor(.bottom)` (see the comment at the modifier's
    /// old position below) — the *binding's initial value* positions the
    /// mount exactly once and is then naturally superseded by user scrolls
    /// and the observers' `scrollTo` writes, whereas the anchor was a
    /// *standing preference* that kept re-litigating the offset against
    /// this binding forever after any long-travel snap. Short content is
    /// unaffected (the `minHeight` floor top-aligns it; nothing scrolls).
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// `true` when the most recent settled (content-stable) geometry
    /// tick saw the user within ``bottomFollowThreshold`` of the bottom.
    /// Initialized `false` so a mount with an in-flight stream
    /// doesn't fire a spurious auto-follow before the first tick.
    @State private var wasAtBottom = false
    /// Latest `ContainerSnapshot`; read by `.onChange(of: verbosity)`
    /// to capture pre-relayout distance-from-bottom.
    ///
    /// Held in a reference box — NOT as a value-typed `@State` — because it
    /// is written on (potentially) every geometry tick and read only inside
    /// the `.onChange(of: verbosity)` event closure, never in `body`. As a
    /// value-typed `@State`, each write invalidates the view; when the
    /// `LazyVStack` reports a *bistable* `contentHeight` (two values
    /// alternating per layout pass), the write → re-render → re-layout →
    /// flipped-height → geometry-tick cycle becomes a self-sustaining
    /// main-thread livelock (observed: ~1,200 ticks/s at 100% CPU, touches
    /// undeliverable, the streaming turn starved — the post-#284
    /// "content disappears" wedge). The #254 identical-snapshot guard can't
    /// break that cycle because alternating snapshots are never equal.
    /// Mutating a property of a reference held by `@State` does not
    /// invalidate the view, which severs the loop's re-render edge while
    /// keeping the latch every bit as fresh for the verbosity observer.
    @State private var latestSnapshotBox = SnapshotBox()

    /// Reference holder for ``latestSnapshotBox`` — see that property for
    /// why this must be a class.
    private final class SnapshotBox {
        var value: ContainerSnapshot?
    }
    /// Active verbosity-driven scroll-restoration mode, set on a
    /// verbosity flip and cleared after
    /// ``verbosityStableTicksToClear`` consecutive content-stable
    /// ticks (handles `LazyVStack`'s occasional `contentHeight`
    /// over-then-under settling pattern).
    @State private var verbosityScrollMode: VerbosityScrollMode?
    /// Counter consumed by the geometry action; resets to 0 on every
    /// content-height change while ``verbosityScrollMode`` is active.
    @State private var verbosityStableTickCount: Int = 0
    /// Total geometry ticks observed since ``verbosityScrollMode`` was set
    /// (independent of content stability). Backstop disarm mirroring
    /// ``pendingBottomSnapTotalTicks``: if the relayout's content height
    /// never holds steady (the bistable `LazyVStack` regime), the
    /// stable-tick counter can't advance and the per-tick `scrollTo`
    /// re-apply would otherwise run unbounded — the same shape as the
    /// stream-end settle's pathology, reachable through the verbosity door.
    @State private var verbosityTotalTicks = 0
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
    /// Total geometry ticks observed since ``pendingBottomSnap`` was armed
    /// (independent of content stability). Backstop disarm for the
    /// tiny-viewport case where ``bottomSnapStableTickCount`` never reaches
    /// its threshold because the `LazyVStack` content height never holds
    /// steady — see ``bottomSnapMaxTicks``.
    @State private var pendingBottomSnapTotalTicks = 0

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
    /// Hard ceiling on how many geometry ticks ``verbosityScrollMode``
    /// stays active regardless of content stability — the verbosity
    /// counterpart of ``bottomSnapMaxTicks``, sized much more generously
    /// because a legitimate verbosity relayout re-measures *every*
    /// on-screen block and can keep content height moving for dozens of
    /// ticks (a 30-block expand legitimately exceeded 24). The backstop
    /// only exists for the bistable never-stable regime, which ticks at
    /// ~75+/s — 60 ticks still terminates it in under a second of
    /// wall-time while staying far above any observed legitimate settle.
    private static let verbosityMaxTicks: Int = 60
    /// Consecutive content-height-stable ticks required to disarm
    /// ``pendingBottomSnap``. Independent of
    /// ``verbosityStableTicksToClear`` (same value today, different
    /// concern — the stream-end settle vs. the verbosity-relayout settle)
    /// so tuning one doesn't silently move the other.
    private static let bottomSnapStableTicksToClear: Int = 3
    /// Hard ceiling on how many geometry ticks ``pendingBottomSnap`` stays
    /// armed, regardless of whether content height ever settles. The normal
    /// settle disarms via ``bottomSnapStableTicksToClear`` in 3–6 ticks; this
    /// budget (~0.5s of layout passes) only fires in the pathological
    /// tiny-viewport case where the bistable `LazyVStack` content height
    /// thrashes forever and the stable-tick counter can't advance. Kept well
    /// above the synthetic harness's per-settle tick count so
    /// `streamEndPersistLandsAtBottom` still disarms via the stable path.
    private static let bottomSnapMaxTicks: Int = 12
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
        // There is deliberately NO `.defaultScrollAnchor(.bottom)` here.
        // A standing bottom-anchor preference and the `scrollPosition`
        // binding are two independent owners of the same offset: after any
        // long-travel programmatic snap (send/stream-end from mid-content)
        // they re-litigate the position against each other *forever* — the
        // offset sloshed in ~1s cycles ~100–200pt short of the bottom,
        // parking the response tail behind the composer, corrupting the
        // drag gesture's at-bottom sampling, and never settling (verified
        // live: removing the anchor alone took post-stream geometry ticks
        // from ~80/s sustained indefinitely to zero). The anchor's one
        // legitimate job — mount at the latest message — is done by the
        // binding's own initial value (`ScrollPosition(edge: .bottom)`),
        // which positions once and is then superseded, keeping the offset
        // single-owner. Both anchor roles are now covered without the
        // modifier: initial position by the binding, short-content
        // top-alignment by the `.frame(minHeight:)` floor on the content
        // (see that comment for why the `.top` alignment-anchor variant
        // was also removed, in #238).
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
            // Snap policy: the user's OWN action (send / regenerate — the
            // new last row is their bubble) always brings them to the
            // bottom, even from deep in history. Assistant-row appends
            // (mid-turn tool-round saves, the final save of a turn) follow
            // only when the user was already at the bottom — a reader
            // scrolled up into history is never yanked by a turn they've
            // scrolled away from; they catch up on their own time. This is
            // also what removes most long-travel animated snaps, the
            // precondition of the post-stream offset fight.
            guard shouldSnapOnItemsChange(
                lastItem: items.last,
                wasAtBottom: wasAtBottom
            ) else { return }
            // Clear any in-flight verbosity scroll mode first so the
            // content-grow tick that follows doesn't re-apply the
            // preserve-distance intent and yank the user back from
            // the bottom we're about to scroll them to.
            verbosityScrollMode = nil
            verbosityStableTickCount = 0
            verbosityTotalTicks = 0
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
            pendingBottomSnapTotalTicks = 0
        }
        // `streamingTail` is the whole `StreamingState`, not just
        // `.text` — the tail grows during the pure-thinking phase via
        // `.thinking` *before* `.text` has any content, and observing
        // only `.text` misses that growth (the user would see the
        // thinking trace push the streaming bubble down out of view).
        // Gated on `wasAtBottom` so a user reading history during a
        // long response isn't yanked down on every coalesced delta.
        .onChange(of: streamingTail) { _, _ in
            // Suppress while a stream-end settle (`pendingBottomSnap`) owns the
            // bottom-pin: that settle already re-snaps on each content-stable
            // tick, and letting the tail observer *also* fire `scrollTo(.bottom)`
            // adds a second, differently-timed scroll input during the exact
            // window the tiny-viewport oscillation lives in. One owner during
            // the settle keeps the scroll cadence single-sourced.
            guard wasAtBottom, !pendingBottomSnap else { return }
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
                // Fall back to `.scrollToBottom` when the snapshot latch
                // hasn't been captured yet (verbosity toggled before
                // the first geometry tick fired). A guaranteed
                // bottom-snap is better than the silent positional
                // jump that would result from setting no mode.
                verbosityScrollMode = latestSnapshotBox.value
                    .map { .preserveDistance($0.distanceFromBottom) }
                    ?? .scrollToBottom
            } else if newValue.rank < oldValue.rank {
                verbosityScrollMode = .scrollToBottom
            } else {
                return
            }
            verbosityStableTickCount = 0
            verbosityTotalTicks = 0
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
            // A reference-box property write — cannot invalidate the view, so
            // it is safe on every tick, including alternating bistable ones.
            // See ``latestSnapshotBox`` for why this must not be a value-typed
            // `@State` write.
            latestSnapshotBox.value = newValue
            // Latch the bottom-status only when this tick wasn't a
            // content-grow event. Content-grow flips `isAtBottom`
            // false (the bottom is suddenly further away) *before*
            // the gated `.onChange` observers run; we want them to
            // see the pre-grow status.
            if oldValue.contentHeight == newValue.contentHeight,
               wasAtBottom != newValue.isAtBottom {
                // Changed-only write: content-stable ticks arrive on every
                // scroll frame, and a same-value `@State` write per frame is
                // gratuitous invalidation pressure on exactly the regimes
                // (bistable layout, programmatic seeks) where extra
                // re-renders feed oscillation.
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
                verbosityTotalTicks += 1
                if oldValue.contentHeight != newValue.contentHeight {
                    verbosityStableTickCount = 0
                    switch mode {
                    case .scrollToBottom:
                        // Same no-op-snap suppression as the stream-end
                        // settle: re-snapping while already pinned at the
                        // bottom only re-materializes `LazyVStack` rows and
                        // feeds the bistable content-height oscillation.
                        if shouldReSnapPendingBottom(
                            contentHeightChanged: true,
                            alreadyAtBottom: newValue.isAtBottom
                        ) {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    case .preserveDistance(let savedDistance):
                        let targetY = max(0, newValue.contentHeight - newValue.height - savedDistance)
                        scrollPosition.scrollTo(y: targetY)
                    }
                } else {
                    verbosityStableTickCount += 1
                }
                // Disarm on the normal settle or an exhausted tick budget —
                // the budget (``verbosityMaxTicks``) is the backstop for a
                // bistable content height that never holds steady, where the
                // stable counter can't advance and the per-tick re-apply
                // would otherwise run unbounded. Mirrors the stream-end
                // settle's disarm shape.
                let verbositySettled = verbosityStableTickCount >= Self.verbosityStableTicksToClear
                let verbosityBudgetSpent = pendingBottomSnapBudgetExhausted(
                    totalTicks: verbosityTotalTicks,
                    maxTicks: Self.verbosityMaxTicks
                )
                if verbositySettled || verbosityBudgetSpent {
                    verbosityScrollMode = nil
                    verbosityStableTickCount = 0
                    verbosityTotalTicks = 0
                }
            }
            // Late-growth auto-follow — the follow role the removed
            // `.defaultScrollAnchor(.bottom)` used to play, reimplemented as
            // a latch-gated tick rule instead of a standing preference (the
            // standing preference is what fought the `scrollPosition`
            // binding into the perpetual post-stream slosh). When the user
            // was at the bottom and content grows past it with no settle
            // owning the scroll, follow it: post-settle materialization (a
            // verbosity relayout's trailing ~72pt), equal-count item growth
            // (a tool result filling into an expanded block), and any other
            // unattributed growth all land here. Loop-safe: fires only on
            // content-grow ticks (never offset-only), is suppressed while
            // either settle owns the cadence, and `!isAtBottom` skips the
            // no-op snaps that fed the #254 tiny-viewport oscillation
            // (whose flip-flop ticks report `isAtBottom == true`).
            if oldValue.contentHeight < newValue.contentHeight,
               wasAtBottom,
               !newValue.isAtBottom,
               verbosityScrollMode == nil,
               !pendingBottomSnap {
                scrollPosition.scrollTo(edge: .bottom)
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
                pendingBottomSnapTotalTicks += 1
                let contentChanged = oldValue.contentHeight != newValue.contentHeight
                if contentChanged {
                    bottomSnapStableTickCount = 0
                } else {
                    bottomSnapStableTickCount += 1
                }
                // Only re-snap on a content-height-change tick where the
                // viewport is *not* already pinned to the bottom. Re-snapping
                // while `isAtBottom` is a no-op for the offset, but in a tiny
                // viewport (handle dragged to ~90pt, keyboard up) it
                // re-materializes the `LazyVStack`'s rows every tick — feeding
                // the bistable `contentHeight` oscillation (observed flip-flop
                // ~3476↔1280 with the offset correctly pinned `gap≈0`) that
                // blanks rows mid-relayout. The trace showed `isAtBottom`
                // already true on every flip-flop tick, so this removes exactly
                // the redundant snaps without weakening the real stream-end
                // settle (where content grows past the bottom → `isAtBottom`
                // false → we still snap).
                if shouldReSnapPendingBottom(
                    contentHeightChanged: contentChanged,
                    alreadyAtBottom: newValue.isAtBottom
                ) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
                // Disarm on either the normal settle (``bottomSnapStableTicksToClear``
                // consecutive content-stable ticks) *or* an exhausted tick budget.
                // The budget is the backstop for the tiny-viewport case where the
                // bistable content height *never* holds steady, so the stable-tick
                // counter never reaches its threshold and the snap would otherwise
                // re-arm forever. A normal viewport settles in 3–6 ticks (well under
                // the budget), so the budget only bites in the pathological case.
                //
                // Evaluated on *every* tick (not only content-stable ones, where the
                // prior implementation kept it) so the budget can fire mid-thrash —
                // its whole purpose is to disarm while content height is still moving.
                let settled = bottomSnapStableTickCount >= Self.bottomSnapStableTicksToClear
                let budgetSpent = pendingBottomSnapBudgetExhausted(
                    totalTicks: pendingBottomSnapTotalTicks,
                    maxTicks: Self.bottomSnapMaxTicks
                )
                if settled || budgetSpent {
                    // Budget-forced-disarm safety net: the stable path only fires
                    // once we're settled at the bottom, but the budget can fire while
                    // content is still growing with the offset stranded *above* the
                    // last row (`isAtBottom == false`). No other observer re-pins that
                    // case — the past-end guard catches only strands *past* the end,
                    // and the container auto-follow needs a height change. Land it
                    // explicitly, once. Skipped when already at the bottom, so the
                    // tiny-viewport oscillation (`isAtBottom` true every tick) gets no
                    // extra snap; harmless either way since we disarm immediately after.
                    if shouldLandOnBudgetDisarm(
                        budgetExhausted: budgetSpent,
                        settled: settled,
                        alreadyAtBottom: newValue.isAtBottom
                    ) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                    pendingBottomSnap = false
                    bottomSnapStableTickCount = 0
                    pendingBottomSnapTotalTicks = 0
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

/// Whether an `items.count` change should bottom-snap the transcript.
/// The user's own action (the new last row is their bubble — send,
/// regenerate accept) always snaps; assistant/banner appends follow only
/// when the user was already at the bottom, so a reader scrolled up into
/// history is never yanked by a turn they've scrolled away from.
///
/// Pure so the policy is unit-testable without a live `ScrollPosition`.
func shouldSnapOnItemsChange(lastItem: MessageList.Item?, wasAtBottom: Bool) -> Bool {
    if case .userBubble = lastItem { return true }
    return wasAtBottom
}

/// Whether the pending stream-end bottom-snap should re-issue
/// `scrollTo(.bottom)` on a given geometry tick. Worth a snap only when the
/// content height actually moved this tick *and* the viewport isn't already
/// pinned to the bottom — re-snapping while already at the bottom is a no-op
/// for the offset that, in a tiny viewport, just re-materializes the
/// `LazyVStack`'s rows and sustains the content-size oscillation that blanks
/// the transcript (the handle-drag-to-tiny-viewport bug).
///
/// Pure so the decision is unit-testable without a live `ScrollPosition`.
func shouldReSnapPendingBottom(contentHeightChanged: Bool, alreadyAtBottom: Bool) -> Bool {
    contentHeightChanged && !alreadyAtBottom
}

/// Whether the pending stream-end bottom-snap has exhausted its tick budget and
/// must disarm regardless of whether content height ever settled. The normal
/// path disarms via a consecutive-content-stable counter; this backstop covers
/// the tiny-viewport case where the bistable `LazyVStack` content height never
/// holds steady, so that counter never advances and the snap would re-arm
/// forever.
///
/// Pure so the disarm boundary is unit-testable.
func pendingBottomSnapBudgetExhausted(totalTicks: Int, maxTicks: Int) -> Bool {
    totalTicks >= maxTicks
}

/// Whether a budget-forced disarm of the stream-end settle must issue one final
/// `scrollTo(.bottom)`. The stable-disarm path only triggers once the viewport
/// is already settled at the bottom, but the tick-budget backstop can fire while
/// content is still growing with the offset stranded *above* the last row — a
/// case no other observer re-pins (the past-end guard catches only strands *past*
/// the end, and the container auto-follow needs a height change). Skipped when
/// already at the bottom so the tiny-viewport oscillation (`isAtBottom` true
/// every tick) gets no extra snap.
///
/// Pure so the safety-net condition is unit-testable.
func shouldLandOnBudgetDisarm(budgetExhausted: Bool, settled: Bool, alreadyAtBottom: Bool) -> Bool {
    budgetExhausted && !settled && !alreadyAtBottom
}
