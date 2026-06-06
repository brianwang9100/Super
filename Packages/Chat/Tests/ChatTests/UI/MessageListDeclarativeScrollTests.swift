#if canImport(UIKit)
import Core
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Chat

/// Tests for `MessageList`'s scroll behavior under the canonical SwiftUI
/// chat-layout pattern: a bottom-anchored `ScrollView` whose
/// `adjustedContentInset.bottom` grows when the keyboard rises (driven by
/// `safeAreaInset(edge: .bottom)` on `ChatScreen`'s content area).
/// `UIScrollView`'s built-in content-inset-preservation logic adjusts
/// `contentOffset` to keep the previously-visible bottom row visible
/// across keyboard show/dismiss — no app-level scroll math. These tests
/// are the regression surface for three bugs an earlier imperative
/// implementation produced:
///   - Keyboard show hid the bottom message (viewport shrank, offset stayed).
///   - Keyboard dismiss left a blank gap below content (viewport grew,
///     offset stayed).
///   - Submit briefly blanked the content area (onChange fired a
///     `scrollTo(.bottom)` against in-flux geometry).
///
/// The keyboard is simulated through `UIHostingController.additionalSafeAreaInsets`
/// — matching how SwiftUI's automatic keyboard avoidance feeds the
/// `safeAreaInset` modifier in production. Pattern otherwise matches
/// `ChatScreenFocusBindingTests`: a `UIHostingController` inside a
/// `UIWindow.makeKeyAndVisible()`-ed window, force-laid-out and settled
/// across a few runloop turns. Assertions read the host's descendant
/// `UIScrollView` — `contentOffset`, `contentSize`, `bounds.size`,
/// `adjustedContentInset.bottom`. SSE = Server-Sent Events;
/// SwiftUI = Apple's declarative UI framework (acronym for orientation).
@Suite("MessageList declarative scroll anchor")
@MainActor
struct MessageListDeclarativeScrollTests {

    // MARK: - Initial position

    /// Short chats (content fits viewport) keep the natural top
    /// alignment — the content's `.frame(minHeight: containerHeight,
    /// alignment: .top)` floor fills the viewport so short content sits at
    /// the top (the floor replaced `.defaultScrollAnchor(.top, for:
    /// .alignment)`). Guards against an accidental anchor regression that
    /// would push short chats to the bottom of the viewport with empty
    /// space above.
    @Test("short chat starts at top with content fitting viewport")
    func shortChatStartsAtTop() async throws {
        let driver = MessageListDriver(items: makeItems(count: 2))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)

        #expect(
            scrollView.contentSize.height <= scrollView.bounds.height + 1,
            "expected content to fit, got contentH=\(scrollView.contentSize.height) viewportH=\(scrollView.bounds.height)"
        )
        #expect(
            scrollView.contentOffset.y == 0,
            "expected top alignment for non-scrollable content, got offsetY=\(scrollView.contentOffset.y)"
        )
    }

    /// **Bug 2 regression — the content `minHeight` floor is active.**
    /// Short content's frame must be floored up to the container height
    /// (`contentSize.height == bounds.height`), not left at its smaller
    /// intrinsic height. That floor is what makes the short→long
    /// transition *continuous* in the container height — there's no
    /// fits-vs-overflows boundary for the old `.defaultScrollAnchor(.top,
    /// for: .alignment)` to flip on, which is what jittered while the
    /// surface was actively resized. Combined with `shortChatStartsAtTop`'s
    /// `contentSize <= bounds + 1`, this pins `contentSize == bounds` for
    /// short content. A regression that dropped the floor would leave
    /// `contentSize < bounds` and reintroduce the bistable flip.
    @Test("short content frame is floored to the container height")
    func shortContentFloorsToContainerHeight() async throws {
        let driver = MessageListDriver(items: makeItems(count: 2))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)

        #expect(
            scrollView.contentSize.height >= scrollView.bounds.height - 1,
            "expected the minHeight floor to fill the viewport, got contentH=\(scrollView.contentSize.height) viewportH=\(scrollView.bounds.height)"
        )
    }

    /// **Bug 1 regression — stream-end persist lands at the bottom.**
    /// Reproduces the stream-end ordering: a streaming tail is showing,
    /// then it's cleared to empty (content shrinks) AND a persisted
    /// assistant row is appended (content grows) within the same settle
    /// window — exactly what `ChatScreenViewModel.assistantMessageSaved`
    /// does. The `pendingBottomSnap` settle re-snap must land the new row
    /// at the bottom after content height stabilizes. (The semi-expanded +
    /// keyboard transient that made the *single* immediate snap miss is
    /// verified on-device; this guards the settle mechanism + no
    /// regression in the synthetic harness.)
    @Test("stream-end clear-tail-then-grow-items lands at bottom")
    func streamEndPersistLandsAtBottom() async throws {
        let driver = MessageListDriver(
            items: makeItems(count: 30),
            streamingTail: MessageList.StreamingState(thinking: "", text: "Streaming reply in progress", isCompacting: false)
        )
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)
        #expect(distanceFromBottom(scrollView) < 2, "preconditions: at bottom while streaming")

        // Mirror `.assistantMessageSaved`: clear the tail to empty and
        // append the persisted row in the same update.
        driver.streamingTail = MessageList.StreamingState(thinking: "", text: "", isCompacting: false)
        driver.items += [makeAssistantItem(id: "persisted-reply", chars: 240)]
        settle(controller: controller)

        let distance = distanceFromBottom(scrollView)
        #expect(
            distance < 2,
            "expected stream-end persist to settle at bottom, got distanceFromBottom=\(distance)"
        )
    }

    /// Long chats land bottom-anchored on first appear — covered by
    /// the no-role `.defaultScrollAnchor(.bottom)` modifier, which
    /// sets the initial offset for an overflowing transcript.
    @Test("long chat opens with bottom message visible")
    func longChatStartsAtBottom() async throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)

        #expect(
            scrollView.contentSize.height > scrollView.bounds.height,
            "preconditions: expected overflowing content"
        )
        let distance = distanceFromBottom(scrollView)
        #expect(
            distance < 2,
            "expected initial position at bottom, got distanceFromBottom=\(distance)"
        )
    }

    // MARK: - Send / streaming
    //
    // Keyboard show/dismiss behavior is verified on-device, not here.
    // The synthetic test harness can't faithfully simulate SwiftUI's
    // automatic keyboard avoidance — both `additionalSafeAreaInsets`
    // (UIKit-level) and host frame resizing (the pre-refactor approach)
    // are stand-ins that don't propagate through SwiftUI's
    // `safeAreaInset` / keyboard-avoidance machinery the way a real
    // `UIResponder.keyboardWillShowNotification` does. Manual
    // verification on iPhone 17 simulator covers the keyboard cases
    // (see plan's Verification section).

    /// Appending a message while at bottom stays at bottom — covered
    /// by the `.onChange(of: items.count) → scrollTo(.bottom)`
    /// handler (the empirically-broken `.defaultScrollAnchor(.bottom,
    /// for: .sizeChanges)` is not relied on).
    @Test("appending a message while at bottom keeps the new message in view")
    func contentGrowAtBottomStaysAtBottom() async throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)
        #expect(distanceFromBottom(scrollView) < 2, "preconditions: at bottom")

        driver.items += [makeUserItem(id: "appended-tail", chars: 180)]
        settle(controller: controller)

        let distance = distanceFromBottom(scrollView)
        #expect(
            distance < 2,
            "expected to remain at bottom after content grew, got distanceFromBottom=\(distance)"
        )
    }

    /// Mounting the live streaming tail (nil → non-nil with empty
    /// thinking/text — the "Waiting spark" state immediately after
    /// send) should land at the bottom of the new content. Covered by
    /// `.onChange(of: streamingTail) → scrollTo(.bottom)` which fires
    /// once per settled tail state (mount, every coalesced delta,
    /// unmount).
    @Test("streaming tail mount lands at the bottom of the new content")
    func streamingTailMountLandsAtBottom() async throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)
        #expect(distanceFromBottom(scrollView) < 2, "preconditions: at bottom")

        driver.streamingTail = MessageList.StreamingState(
            thinking: "",
            text: "",
            isCompacting: false
        )
        settle(controller: controller)

        let distance = distanceFromBottom(scrollView)
        #expect(
            distance < 2,
            "expected to land at bottom after streamingTail mount, got distanceFromBottom=\(distance)"
        )
    }

    /// Streaming-tail *thinking* growth (no visible text yet) must
    /// keep the bubble at the bottom. The naive observer
    /// `.onChange(of: streamingTail?.text)` would miss this entirely
    /// because `.text` stays empty during the pure-thinking phase —
    /// the user would see the thinking trace push the streaming
    /// bubble silently below the viewport. Observing the whole
    /// `streamingTail` struct catches it.
    @Test("streaming tail thinking-only growth stays at bottom")
    func streamingThinkingGrowthStaysAtBottom() async throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)
        #expect(distanceFromBottom(scrollView) < 2, "preconditions: at bottom")

        // Mount the tail in pure-thinking state, then grow `thinking`
        // without ever touching `.text` — the production shape when
        // the model emits a thinking trace before any reply text.
        driver.streamingTail = MessageList.StreamingState(
            thinking: "Considering the question",
            text: "",
            isCompacting: false
        )
        settle(controller: controller)
        let longerThinking = String(repeating: "More thinking. ", count: 80)
        driver.streamingTail = MessageList.StreamingState(
            thinking: longerThinking,
            text: "",
            isCompacting: false
        )
        settle(controller: controller)

        let distance = distanceFromBottom(scrollView)
        #expect(
            distance < 2,
            "expected to remain at bottom after thinking growth, got distanceFromBottom=\(distance)"
        )
    }

    /// **Negative test for the `wasAtBottom` guard on the
    /// streaming-tail observer.** A user scrolled up reading history
    /// during a long response must not be yanked back to the bottom
    /// when a streaming-tail delta arrives — that's the load-bearing
    /// behavior the `guard wasAtBottom else { return }` line in the
    /// `.onChange(of: streamingTail)` handler exists to guarantee. A
    /// future regression that drops the guard would pass every other
    /// streaming test; this one fails.
    @Test("streaming tail growth does not scroll when user is reading history")
    func streamingTailGrowthDoesNotScrollWhenScrolledUp() async throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)

        // Scroll up ~300pt so `wasAtBottom` latches false.
        let targetOffsetY = scrollView.contentSize.height - scrollView.bounds.height - 300
        scrollView.setContentOffset(CGPoint(x: 0, y: max(0, targetOffsetY)), animated: false)
        settle(controller: controller)
        let positionBefore = scrollView.contentOffset.y

        driver.streamingTail = MessageList.StreamingState(
            thinking: "",
            text: "Hello",
            isCompacting: false
        )
        settle(controller: controller)

        // The user's contentOffset must not move further toward the
        // bottom than a couple of points (room for sub-pixel layout
        // jitter from the tail's mount itself).
        #expect(
            scrollView.contentOffset.y <= positionBefore + 2,
            "streaming tail must not yank a reading-history user to the bottom; moved from \(positionBefore) to \(scrollView.contentOffset.y)"
        )
    }

    // MARK: - Verbosity-driven relayout

    /// Flipping verbosity from `.simple` → `.thinking` expands every
    /// on-screen `ThinkingBlock`, growing content height by hundreds
    /// of points. When the user was *at the bottom*, they expect to
    /// stay at the bottom of the new content (latest message
    /// visible). The two-phase intent capture in
    /// `.onChange(of: verbosity)` plus the consume in
    /// `.onScrollGeometryChange`'s action handles this.
    @Test("verbosity expand from bottom stays at bottom")
    func verbosityExpandAtBottomStaysAtBottom() async throws {
        let driver = MessageListDriver(items: makeItemsWithThinking(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)
        #expect(distanceFromBottom(scrollView) < 2, "preconditions: at bottom")
        let beforeContentHeight = scrollView.contentSize.height

        driver.verbosity = .thinking
        settle(controller: controller)

        #expect(
            scrollView.contentSize.height > beforeContentHeight,
            "preconditions: expected verbosity expand to grow content, got \(scrollView.contentSize.height) vs before \(beforeContentHeight)"
        )
        let distance = distanceFromBottom(scrollView)
        #expect(
            distance < 4,
            "expected to stay at bottom after verbosity expand, got distanceFromBottom=\(distance)"
        )
    }

    /// Flipping verbosity while *scrolled up reading history* must
    /// preserve the user's chat-region position. Expansion adds
    /// content above the visible region; the
    /// preserve-distance-from-bottom intent compensates so the user
    /// sees roughly the same chat region. Without the intent, the
    /// user would be silently dropped backward in the conversation.
    @Test("verbosity expand from mid-scroll preserves distance from bottom")
    func verbosityExpandFromHistoryPreservesPosition() async throws {
        let driver = MessageListDriver(items: makeItemsWithThinking(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)

        // Scroll up to ~300pt from the bottom (mid-history).
        let targetOffsetY = scrollView.contentSize.height - scrollView.bounds.height - 300
        scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
        settle(controller: controller)
        let beforeDistance = distanceFromBottom(scrollView)
        #expect(
            abs(beforeDistance - 300) < 10,
            "preconditions: expected ~300pt from bottom, got \(beforeDistance)"
        )

        driver.verbosity = .thinking
        // 30 iterations × 40 ms = 1.2 s; `LazyVStack` typically settles
        // within a handful of geometry ticks, and the mode auto-clears
        // after ``verbosityStableTicksToClear`` (= 3) consecutive
        // content-height-stable ticks, well before the settle finishes.
        settle(controller: controller, iterations: 30)

        // Tolerance of 60pt accommodates `LazyVStack`'s row-height
        // refinement: it can overestimate `contentHeight` on the
        // last visible scroll tick and refine downward later, after
        // ``verbosityScrollMode`` has cleared. The realistic UX
        // outcome is the user lands within one row of their previous
        // position — meaningfully better than the no-handler baseline
        // (where distance would be off by the full ~1500pt of newly-
        // expanded content above them).
        let afterDistance = distanceFromBottom(scrollView)
        #expect(
            abs(afterDistance - 300) < 60,
            "expected distance from bottom preserved (~300pt) across verbosity expand, got \(afterDistance)"
        )
    }

    /// Sending a new message inside the verbosity-scroll settling
    /// window must land at the bottom of the new content, *not* be
    /// pulled back to the pre-flip distance by a still-active
    /// `verbosityScrollMode`. The `.onChange(of: items.count)`
    /// handler clears the verbosity mode before scrolling to bottom
    /// — otherwise the content-grow tick from the appended item
    /// would re-apply the preserve-distance intent and strand the
    /// user `savedDistance` above the latest message.
    @Test("appending a message during verbosity settle lands at bottom")
    func appendAfterVerbosityFlipLandsAtBottom() async throws {
        let driver = MessageListDriver(items: makeItemsWithThinking(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)

        // Scroll up so the verbosity flip captures a non-zero
        // preserve-distance, then immediately flip verbosity and
        // append an item before the settling window closes.
        let targetOffsetY = scrollView.contentSize.height - scrollView.bounds.height - 300
        scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
        settle(controller: controller)

        driver.verbosity = .thinking
        // Drive only one settle iteration so the verbosity mode is
        // still active when the append happens — the bug repro
        // requires the mode to outlive the items-count change.
        settle(controller: controller, iterations: 1)
        driver.items += [makeUserItem(id: "sent-during-settle", chars: 60)]
        settle(controller: controller, iterations: 30)

        let distance = distanceFromBottom(scrollView)
        #expect(
            distance < 4,
            "expected to land at bottom after send-during-verbosity-settle, got distanceFromBottom=\(distance)"
        )
    }

    // MARK: - Feedback-loop regression

    /// **Regression test for the on-device hang.** An earlier
    /// implementation drove scroll restoration from an
    /// `onScrollGeometryChange` action that called
    /// `scrollPosition.scrollTo(y:)` on every geometry tick. SwiftUI's
    /// automatic keyboard avoidance interpolates the bottom safe-area
    /// inset across the keyboard animation (~250 ms), so every frame
    /// fired a geometry tick → state mutation → re-render → geometry
    /// tick. The recursion saturated the main runloop and the app
    /// locked up. The declarative architecture has no such state seam:
    /// `MessageList` no longer mutates any `@State` from a geometry
    /// observer. This test rapidly toggles the host's frame size — the
    /// pre-refactor trigger shape — and asserts the test thread
    /// completes within 1 second. A regression would hang far past that.
    @Test("rapid container size toggles do not hang the runloop")
    func focusToggleDoesNotHang() async throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }

        settle(controller: controller)
        let scrollView = try requireScrollView(in: controller)
        #expect(distanceFromBottom(scrollView) < 2, "preconditions: at bottom")

        let elapsed = rapidResizeStorm(controller: controller, iterations: 10)
        #expect(
            elapsed < 1.0,
            "expected rapid resizes to complete quickly, took \(elapsed)s"
        )
    }

    // MARK: - Helpers

    /// Standard host scaffolding: hosting controller, key window, frame
    /// set to window bounds. The window must be `makeKeyAndVisible()` so
    /// SwiftUI's scroll layout proceeds (mirrors the load-bearing detail
    /// in `ChatScreenFocusBindingTests`).
    @MainActor
    private func makeHost(
        driver: MessageListDriver,
        height: CGFloat
    ) -> (UIHostingController<MessageListHost>, UIWindow) {
        let host = MessageListHost(driver: driver)
        let controller = UIHostingController(rootView: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: height))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        return (controller, window)
    }

    @MainActor
    private func teardown(window: UIWindow) {
        window.resignKey()
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Rapidly toggle the host's frame size `iterations` times,
    /// pumping the runloop briefly after each toggle. Returns the
    /// elapsed wall time so the caller can assert no hang occurred.
    /// Lives as a synchronous `@MainActor` helper because
    /// `RunLoop.main.run(until:)` is unavailable from async contexts
    /// in Swift 6.
    @MainActor
    private func rapidResizeStorm(
        controller: UIViewController,
        iterations: Int
    ) -> TimeInterval {
        let baseSize = controller.view.bounds.size
        let shrunkSize = CGSize(width: baseSize.width, height: baseSize.height - 300)
        let start = Date()
        for index in 0..<iterations {
            let size = index.isMultiple(of: 2) ? shrunkSize : baseSize
            controller.view.window?.frame = CGRect(origin: .zero, size: size)
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return Date().timeIntervalSince(start)
    }

    /// Settle the SwiftUI layout: alternate `setNeedsLayout` /
    /// `layoutIfNeeded` calls with brief runloop pumps so size-change
    /// anchors and any pending `scrollPosition.scrollTo(y:)` calls
    /// converge across multiple ticks (LazyVStack lazy materialization
    /// fires several geometry ticks per resize). `RunLoop.main.run(until:)`
    /// is a synchronous pump — preferable to `Task.sleep` per
    /// AGENTS.md §Testing.2.
    @MainActor
    private func settle(controller: UIViewController, iterations: Int = 6) {
        for _ in 0..<iterations {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        }
    }

    private func makeItems(count: Int) -> [MessageList.Item] {
        (0..<count).map { idx in
            idx.isMultiple(of: 2)
                ? makeUserItem(id: "user-\(idx)", chars: 120)
                : makeAssistantItem(id: "assistant-\(idx)", chars: 240)
        }
    }

    private func makeUserItem(id: String, chars: Int) -> MessageList.Item {
        let token = "user message "
        let repeatCount = max(1, chars / token.count)
        return .userBubble(
            id: id,
            text: String(repeating: token, count: repeatCount),
            references: []
        )
    }

    private func makeAssistantItem(id: String, chars: Int) -> MessageList.Item {
        let token = "assistant reply "
        let repeatCount = max(1, chars / token.count)
        return .assistantText(
            id: id,
            thinking: nil,
            thinkingDurationMs: nil,
            text: String(repeating: token, count: repeatCount),
            toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
        )
    }

    /// Alternates user/assistant items like `makeItems(count:)`, but
    /// every assistant message carries a multi-line thinking trace so
    /// flipping `verbosity` from `.simple` to `.thinking` expands a
    /// visible block on each row and meaningfully grows content
    /// height. Used by the verbosity-driven scroll tests.
    private func makeItemsWithThinking(count: Int) -> [MessageList.Item] {
        let thinking = String(repeating: "Considering the question. ", count: 16)
        return (0..<count).map { idx in
            if idx.isMultiple(of: 2) {
                return makeUserItem(id: "user-\(idx)", chars: 120)
            }
            return .assistantText(
                id: "assistant-\(idx)",
                thinking: thinking,
                thinkingDurationMs: 1_200,
                text: String(repeating: "assistant reply ", count: 16),
                toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil
            )
        }
    }

    private func requireScrollView(in controller: UIViewController) throws -> UIScrollView {
        guard let scrollView = controller.view.findFirstScrollView() else {
            throw MessageListScrollTestError.scrollViewNotFound
        }
        return scrollView
    }

    /// Points between the bottom of the visible viewport and the bottom
    /// of the content. Zero means pinned to the latest message.
    private func distanceFromBottom(_ scrollView: UIScrollView) -> CGFloat {
        max(0, scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height)
    }
}

private enum MessageListScrollTestError: Error {
    case scrollViewNotFound
}

/// Observable container the host reads from. Mutating its properties
/// triggers a SwiftUI re-render of the embedded `MessageList`.
@MainActor
@Observable
private final class MessageListDriver {
    var items: [MessageList.Item]
    var streamingTail: MessageList.StreamingState?
    var verbosity: ChatVerbosity

    init(
        items: [MessageList.Item],
        streamingTail: MessageList.StreamingState? = nil,
        verbosity: ChatVerbosity = .simple
    ) {
        self.items = items
        self.streamingTail = streamingTail
        self.verbosity = verbosity
    }
}

/// Thin SwiftUI host that reads from the observable driver so test bodies
/// can mutate inputs and watch the layout converge. `.ignoresSafeArea()`
/// pulls the scroll view out from under the simulator window's
/// status-bar / home-indicator insets so `contentOffset` arithmetic is
/// straight (no hidden `adjustedContentInset` to subtract from every
/// assertion). The production architecture wraps `MessageList` in a
/// `safeAreaInset(edge: .bottom)` (`ChatScreen`); we don't replicate that
/// here because the synthetic keyboard simulation
/// (`additionalSafeAreaInsets.bottom`) doesn't propagate to a
/// `ScrollView` through SwiftUI's `safeAreaInset` modifier the same way
/// a real `UIResponder.keyboardWillShowNotification` does. The
/// keyboard-show/dismiss behavior is therefore verified on-device,
/// not in this synthetic harness.
private struct MessageListHost: View {
    let driver: MessageListDriver

    var body: some View {
        MessageList(
            items: driver.items,
            streamingTail: driver.streamingTail,
            verbosity: driver.verbosity
        )
        .ignoresSafeArea()
    }
}

private extension UIView {
    /// Depth-first search for the first descendant `UIScrollView`. The
    /// SwiftUI `ScrollView` inside `MessageList` is backed by a UIKit
    /// `UIScrollView`; this helper locates it so tests can read offset
    /// and size without bridging through `ScrollPosition`.
    func findFirstScrollView() -> UIScrollView? {
        if let scroll = self as? UIScrollView { return scroll }
        for sub in subviews {
            if let found = sub.findFirstScrollView() { return found }
        }
        return nil
    }
}
#endif
