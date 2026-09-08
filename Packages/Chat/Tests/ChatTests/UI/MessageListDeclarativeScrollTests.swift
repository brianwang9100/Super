#if canImport(UIKit)
import Core
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Chat

/// Real SwiftUI/UIScrollView integration coverage for explicit turn focus
/// and stationary responses. The bounded runloop pump settles UI layout;
/// async repository/event behavior is tested with deterministic drain seams.
// Window ownership and runloop-driven layout are shared UIKit state.
@Suite("MessageList stationary responses", .serialized)
@MainActor
struct MessageListDeclarativeScrollTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("short history fills the viewport and starts at the top")
    func shortChatStartsAtTop() throws {
        let driver = MessageListDriver(items: makeItems(count: 2))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        #expect(abs(scroll.contentSize.height - scroll.bounds.height) < 1)
        #expect(scroll.contentOffset.y == 0)
    }

    @Test("long history opens at the latest content")
    func longChatStartsAtBottom() throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        #expect(scroll.contentSize.height > scroll.bounds.height)
        #expect(distanceFromBottom(scroll) < 2)
    }

    @Test("send from history places a short user message at the top")
    func sendFocusesUserAtTop() throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        settle(controller: controller)
        let historyHeight = scroll.contentSize.height
        driver.items += [makeUserItem(id: "sent", chars: 60)]
        driver.scrollRequest = .init(messageID: "sent", sequence: 1)
        driver.streamingTail = .init(thinking: "", text: "", isCompacting: false)
        settle(controller: controller)
        #expect(scroll.contentSize.height >= historyHeight + scroll.bounds.height - 20,
                "sending reserves a full viewport for the new turn")
        try expectMessageAtTop("sent", controller: controller)
    }

    @Test("first send and short completion keep the user message at the top")
    func firstSendAndShortCompletionStayStill() throws {
        let driver = MessageListDriver(items: [makeUserItem(id: "first", chars: 60)])
        driver.scrollRequest = .init(messageID: "first", sequence: 1)
        driver.streamingTail = .init(thinking: "", text: "", isCompacting: false)
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        let position = scroll.contentOffset.y
        driver.items += [makeAssistantItem(id: "answer", chars: 30)]
        driver.streamingTail = nil
        settle(controller: controller)
        #expect(abs(scroll.contentOffset.y - position) < 2)
        try expectMessageAtTop("first", controller: controller)
    }

    @Test("streaming grows past the viewport without moving it", arguments: [false, true])
    func streamingGrowthAtBottomStaysStationary(thinking: Bool) throws {
        let driver = MessageListDriver(
            items: makeItems(count: 30),
            streamingTail: .init(thinking: "", text: "Beginning of the reply.", isCompacting: false),
            verbosity: .thinking
        )
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        let position = scroll.contentOffset.y
        let height = scroll.contentSize.height
        let text = String(repeating: "The response continues below. ", count: 100)
        driver.streamingTail = .init(thinking: thinking ? text : "", text: thinking ? "" : text, isCompacting: false)
        settle(controller: controller)
        #expect(scroll.contentSize.height > height + 200)
        #expect(abs(scroll.contentOffset.y - position) < 2)
    }

    @Test("assistant saves do not move a reader at the bottom")
    func assistantAppendAtBottomStaysStationary() throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        let position = scroll.contentOffset.y
        driver.items += [makeAssistantItem(id: "new-assistant", chars: 900)]
        settle(controller: controller)
        #expect(abs(scroll.contentOffset.y - position) < 2)
    }

    @Test("manual scrolling remains in control during a response")
    func manualScrollSurvivesDeltas() throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        driver.items += [makeUserItem(id: "sent", chars: 60)]
        driver.scrollRequest = .init(messageID: "sent", sequence: 1)
        driver.streamingTail = .init(thinking: "", text: String(repeating: "Reading text. ", count: 160), isCompacting: false)
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 150), animated: false)
        settle(controller: controller)
        let position = scroll.contentOffset.y
        driver.streamingTail = .init(thinking: "", text: String(repeating: "Reading text. ", count: 200), isCompacting: false)
        settle(controller: controller)
        #expect(abs(scroll.contentOffset.y - position) < 2)
    }

    @Test("repeated requests and successive sends focus the requested turn")
    func successiveRequestsFocusAtTop() throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        driver.items += [makeUserItem(id: "first", chars: 60)]
        driver.scrollRequest = .init(messageID: "first", sequence: 1)
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        settle(controller: controller)
        driver.scrollRequest = .init(messageID: "first", sequence: 2)
        settle(controller: controller)
        try expectMessageAtTop("first", controller: controller)
        driver.items += [makeAssistantItem(id: "answer", chars: 60), makeUserItem(id: "second", chars: 60)]
        driver.scrollRequest = .init(messageID: "second", sequence: 3)
        settle(controller: controller)
        try expectMessageAtTop("second", controller: controller)
    }

    @Test("stopping or failing retains the readable partial response", arguments: [false, true])
    func interruptionStaysStill(failed: Bool) throws {
        let tail = MessageList.StreamingState(thinking: "", text: String(repeating: "Readable partial response. ", count: 180), isCompacting: false)
        let driver = MessageListDriver(items: makeItems(count: 30), streamingTail: tail)
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y - 100), animated: false)
        settle(controller: controller)
        let position = scroll.contentOffset.y
        driver.interruptedResponse = tail
        driver.streamingTail = nil
        if failed { driver.error = .init(message: "Connection lost.") }
        settle(controller: controller)
        #expect(abs(scroll.contentOffset.y - position) < 2)
        #expect(scroll.contentSize.height > position + 500)
    }

    @Test("a user message taller than the viewport starts at its beginning")
    func oversizedUserStartsAtTop() throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        driver.items += [makeUserItem(id: "long-user", chars: 2400)]
        driver.scrollRequest = .init(messageID: "long-user", sequence: 1)
        settle(controller: controller)
        #expect(distanceFromBottom(scroll) > 600,
                "a long user's first lines, not its bottom, must be visible")
        let position = scroll.contentOffset.y
        driver.streamingTail = .init(thinking: "", text: String(repeating: "More response. ", count: 100), isCompacting: false)
        settle(controller: controller)
        #expect(abs(scroll.contentOffset.y - position) < 2)
    }

    @Test("a long live response is replaced without moving the reader")
    func longResponseHandoffStaysStill() throws {
        let text = String(repeating: "Visible response paragraph.\n\n", count: 80)
        let driver = MessageListDriver(items: makeItems(count: 30), streamingTail: .init(thinking: "", text: text, isCompacting: false))
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y - 200), animated: false)
        settle(controller: controller)
        let position = scroll.contentOffset.y
        driver.items += [.assistantText(id: "saved", thinking: nil, thinkingDurationMs: nil, text: text,
            toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil)]
        driver.streamingTail = nil
        settle(controller: controller)
        #expect(abs(scroll.contentOffset.y - position) < 2)
        #expect(scroll.contentSize.height > position + 500)
    }

    @Test("tiny viewport and rapid resizes stay responsive")
    func focusToggleDoesNotHang() throws {
        let driver = MessageListDriver(items: makeItems(count: 30))
        driver.items += [makeUserItem(id: "sent", chars: 60)]
        driver.scrollRequest = .init(messageID: "sent", sequence: 1)
        let (controller, window) = makeHost(driver: driver, height: 600)
        defer { teardown(window: window) }
        settle(controller: controller)
        #expect(rapidResizeStorm(controller: controller, iterations: 10) < 1)
        window.frame.size.height = 90
        controller.view.frame = window.bounds
        driver.streamingTail = .init(thinking: "", text: String(repeating: "Reply. ", count: 100), isCompacting: false)
        settle(controller: controller)
        let scroll = try requireScrollView(in: controller)
        #expect(scroll.contentOffset.y <= max(0, scroll.contentSize.height - scroll.bounds.height) + 4)
    }

    private func expectMessageAtTop(_ id: String, controller: UIViewController) throws {
        let scroll = try requireScrollView(in: controller)
        // A short focused turn occupies a viewport, so its beginning is
        // the content's trailing viewport. This also checks that the blank
        // response reserve survives completion, independently of text layout.
        #expect(distanceFromBottom(scroll) < 2,
                "requested turn \(id) should occupy the trailing viewport")
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
    var scrollRequest: MessageList.ScrollRequest?
    var interruptedResponse: MessageList.StreamingState?
    var error: MessageList.ErrorState?

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
            error: driver.error,
            scrollRequest: driver.scrollRequest,
            interruptedResponse: driver.interruptedResponse,
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
