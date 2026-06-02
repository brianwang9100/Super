#if canImport(UIKit)
import Core
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Chat

/// Tests that `ChatScreen` honours an externally-owned composer focus
/// binding — the load-bearing contract behind the "minimize chat →
/// keyboard stays dismissed across re-expand" fix.
///
/// Before this fix `composerIsFocused` was a private `@FocusState` inside
/// `ChatScreen`, which the shell could not clear from outside. Result:
/// when the user minimized the chat (drag, applet switch, hamburger
/// menu, …), the UIKit `resignFirstResponder` dispatch hid the keyboard
/// visually but `@FocusState` stayed set; the next re-expand re-focused
/// the field and slid the keyboard back up. Lifting the binding out and
/// having both the shell and `ChatScreen` write through the same
/// `FocusState<Bool>.Binding` is what makes the dismissal durable.
@Suite("ChatScreen external composer focus binding")
@MainActor
struct ChatScreenFocusBindingTests {
    /// When `progress` crosses below the editor-interactive threshold,
    /// `ChatScreen`'s `.onChange(of: progress)` fires `dismissKeyboard()`,
    /// which writes `false` through whichever focus binding is in scope.
    /// This test owns the `@FocusState` externally (just like the shell
    /// does in production) and confirms the threshold cross flips the
    /// host's binding — proving the shell-owned focus state is what
    /// gets cleared, not a stale internal copy.
    @Test("threshold cross flips externally-owned composer focus binding to false")
    func thresholdCrossClearsExternalFocusBinding() async throws {
        let viewModel = makeNoopViewModel()
        let observer = FocusObserver()
        let progressDriver = ProgressDriver(value: 1)

        let host = ExternalFocusHost(
            viewModel: viewModel,
            progressDriver: progressDriver,
            observer: observer
        )

        let controller = UIHostingController(rootView: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        // `makeKeyAndVisible()` (not just `isHidden = false`) is load-bearing:
        // SwiftUI's `@FocusState`-driven `becomeFirstResponder` requires a key
        // window. Without it UIKit refuses focus and SwiftUI auto-reverts
        // `isFocused` to `false` via a delayed `onChange` — which would let
        // the `waitFor(false)` assertion below resolve from the revert rather
        // than from the threshold-cross dismissal we're trying to verify
        // (false positive that survives even reverting the fix).
        window.makeKeyAndVisible()
        defer {
            window.resignKey()
            window.isHidden = true
            window.rootViewController = nil
        }

        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        // `.onAppear` flips the host's `@FocusState` to true; await the
        // observable signal rather than yielding a fixed number of
        // runloop ticks (per AGENTS.md §Testing.2 — `Task.yield`
        // polling is a race amplifier, not a synchronization primitive).
        await observer.waitFor(true)

        // Drive the threshold crossing — observable progress goes from 1
        // (expanded, composer interactive) to 0 (minimized pill,
        // composer disabled). `.onChange(of: progress)` inside
        // `ChatScreen` should fire `dismissKeyboard()` exactly once on
        // this downward crossing.
        progressDriver.value = 0
        controller.view.layoutIfNeeded()
        await observer.waitFor(false)

        #expect(observer.value == false, "external focus binding should be cleared by threshold-cross dismissal")
    }
}

/// Bridges the host's `@FocusState` to the test by recording the latest
/// value `onChange` reported and resuming any awaiters expecting that
/// value. Tests `await observer.waitFor(expected)` instead of polling
/// `Task.yield()` so the synchronization is deterministic — the
/// continuation resumes the exact tick the SwiftUI value transitions.
@MainActor
private final class FocusObserver {
    private(set) var value: Bool = false
    private var waiters: [(expected: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    /// Called from the host's `.onChange(of: isFocused)`. Records the
    /// new value and resumes any waiters whose expected value matches.
    func update(_ newValue: Bool) {
        value = newValue
        let (matched, remaining) = waiters.partitioned { $0.expected == newValue }
        waiters = remaining
        for waiter in matched {
            waiter.continuation.resume()
        }
    }

    /// Suspends until `update(_:)` reports `expected`. Returns
    /// immediately if `value` already matches, so an awaiter that
    /// arrives after the transition still sees it. The test runner's
    /// timeout catches the case where the value never arrives.
    func waitFor(_ expected: Bool) async {
        if value == expected { return }
        await withCheckedContinuation { continuation in
            waiters.append((expected, continuation))
        }
    }
}

private extension Array {
    /// Splits the array into elements matching `isMatch` and the rest,
    /// preserving order in both — used to resume matching focus waiters
    /// while keeping the remaining queue intact.
    func partitioned(by isMatch: (Element) -> Bool) -> (matched: [Element], remaining: [Element]) {
        var matched: [Element] = []
        var remaining: [Element] = []
        for element in self {
            if isMatch(element) {
                matched.append(element)
            } else {
                remaining.append(element)
            }
        }
        return (matched, remaining)
    }
}

/// Drives `ChatScreen.progress` from a test, since `progress` is a `let`
/// on `ChatScreen` and a re-render only happens when an `@Observable`
/// the host depends on changes.
@MainActor
@Observable
private final class ProgressDriver {
    var value: Double
    init(value: Double) { self.value = value }
}

/// Host view that owns `@FocusState` the way `AppShell` does in
/// production, plus the progress driver and observer the test reads.
private struct ExternalFocusHost: View {
    let viewModel: ChatScreenViewModel
    let progressDriver: ProgressDriver
    let observer: FocusObserver

    @FocusState private var isFocused: Bool

    var body: some View {
        ChatScreen(
            viewModel: viewModel,
            progress: progressDriver.value,
            composerIsFocused: $isFocused
        )
        .onAppear {
            isFocused = true
            observer.update(isFocused)
        }
        .onChange(of: isFocused) { _, newValue in
            observer.update(newValue)
        }
    }
}

@MainActor
private func makeNoopViewModel() -> ChatScreenViewModel {
    ChatScreenViewModel(
        conversationId: "focus-binding-test",
        conversationTitle: "Focus binding test",
        driver: NoopDriver(),
        messageRepository: NoopMessageRepository(),
        toolCallRepository: NoopToolCallRepository(),
        checkpointRepository: NoopCheckpointRepository(),
        availableModels: []
    )
}

private struct NoopDriver: ChatSessionDriver {
    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent> {
        AsyncStream { $0.finish() }
    }
    func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        AsyncStream { $0.finish() }
    }
    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        (nil, AsyncStream { $0.finish() })
    }
    func cancel() async {}
    func confirmToolCall(id: String) async {}
    func skipToolCall(id: String) async {}
}

private actor NoopMessageRepository: MessageRepository {
    func fetchAll(conversationId: String) async throws -> [MessageRecord] { [] }
    func fetch(id: String) async throws -> MessageRecord? { nil }
    func hasUserMessage(conversationId: String) async throws -> Bool { false }
    func save(_ record: MessageRecord) async throws {}
    func delete(ids: [String]) async throws {}
    func deleteAll(conversationId: String) async throws {}
}

private actor NoopToolCallRepository: ToolCallRepository {
    func fetchByConversation(_ conversationId: String) async throws -> [ToolCallRecord] { [] }
    func fetchByMessage(_ messageId: String) async throws -> [ToolCallRecord] { [] }
    func fetchByStatus(_ status: ToolCallStatus) async throws -> [ToolCallRecord] { [] }
    func fetch(id: String) async throws -> ToolCallRecord? { nil }
    func save(_ record: ToolCallRecord) async throws {}
    func updateStatus(id: String, status: ToolCallStatus, result: String?, completedAt: Date?) async throws {}
}

private actor NoopCheckpointRepository: CompactionCheckpointRepository {
    func liveCheckpoint(for conversationId: String) async throws -> CompactionCheckpointRecord? { nil }
    func all(for conversationId: String) async throws -> [CompactionCheckpointRecord] { [] }
    func save(_ record: CompactionCheckpointRecord) async throws {}
    func delete(ids: [String]) async throws {}
}
#endif
