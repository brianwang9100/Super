import Foundation

/// Cancels the old revert on every copy so an earlier tap cannot clear newer feedback.
@Observable
@MainActor
final class CodeBlockCopyController {
    enum CopyState: Equatable {
        case idle
        case copied
    }

    private(set) var state: CopyState = .idle

    // The host swaps in its environment client onAppear; State initialization cannot read it.
    var pasteboard: any PasteboardClient

    private let revertDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var revertTask: Task<Void, Never>?

    init(
        pasteboard: any PasteboardClient,
        revertDelay: Duration = .seconds(1.2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.pasteboard = pasteboard
        self.revertDelay = revertDelay
        self.sleep = sleep
    }

    func copy(_ text: String) {
        pasteboard.copy(text)
        state = .copied
        revertTask?.cancel()
        let sleep = self.sleep
        let delay = revertDelay
        revertTask = Task { [weak self] in
            try? await sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.state = .idle
        }
    }

    /// Drains the latest revert; no-op when none is pending.
    func _waitForRevert() async {
        await revertTask?.value
    }
}
