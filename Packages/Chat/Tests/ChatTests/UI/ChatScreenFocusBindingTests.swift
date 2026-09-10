#if canImport(UIKit)
import Core
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Chat

// Hiding the keyboard without clearing shell-owned FocusState lets it reappear on expansion.
@Suite("ChatScreen external composer focus binding")
@MainActor
struct ChatScreenFocusBindingTests {
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
        // FocusState requires a key window. Otherwise UIKit rejects focus and SwiftUI
        // reverts it, creating a false positive for the dismissal assertion.
        window.makeKeyAndVisible()
        defer {
            window.resignKey()
            window.isHidden = true
            window.rootViewController = nil
        }

        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        await observer.waitFor(true)

        progressDriver.value = 0
        controller.view.layoutIfNeeded()
        await observer.waitFor(false)

        #expect(observer.value == false, "external focus binding should be cleared by threshold-cross dismissal")
    }
}

/// Resumes waiters from observed focus changes without runloop polling.
@MainActor
private final class FocusObserver {
    private(set) var value: Bool = false
    private var waiters: [(expected: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func update(_ newValue: Bool) {
        value = newValue
        let (matched, remaining) = waiters.partitioned { $0.expected == newValue }
        waiters = remaining
        for waiter in matched {
            waiter.continuation.resume()
        }
    }

    func waitFor(_ expected: Bool) async {
        if value == expected { return }
        await withCheckedContinuation { continuation in
            waiters.append((expected, continuation))
        }
    }
}

private extension Array {
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

// Observable input forces the host to rebuild ChatScreen with changed progress.
@MainActor
@Observable
private final class ProgressDriver {
    var value: Double
    init(value: Double) { self.value = value }
}

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
