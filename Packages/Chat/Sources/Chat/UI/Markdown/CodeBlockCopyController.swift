import Foundation

/// Drives the copy-pill state machine for a single ``CodeBlock`` —
/// writes to the injected pasteboard, flips state to `.copied`, and
/// reverts to `.idle` after a brief window.
///
/// Lifted out of the SwiftUI view so the timing + cancellation logic can
/// be tested without standing up a SwiftUI render. The previous in-view
/// implementation spawned a fire-and-forget `Task` per tap with no
/// cancellation — rapid taps then raced and an older revert would wipe
/// a newer `.copied` state. This controller cancels the prior revert
/// before scheduling a new one so the visible state always tracks the
/// most recent tap.
@Observable
@MainActor
final class CodeBlockCopyController {
    enum CopyState: Equatable {
        case idle
        case copied
    }

    private(set) var state: CopyState = .idle

    /// Pasteboard the controller writes to. `var` so the host view can
    /// hot-swap to the env-injected implementation in `onAppear` (the
    /// `@State` default constructor doesn't have access to environment
    /// values at struct-init time, so we seed with the system client and
    /// replace once the env is readable).
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

    /// Push `text` to the pasteboard, flip to `.copied`, and schedule a
    /// revert to `.idle` after `revertDelay`. A second call before the
    /// revert fires cancels the pending revert and restarts the timer
    /// against the new tap.
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

    /// Test seam: await the most recently scheduled revert task so a test
    /// can assert the post-revert `.idle` state on an observable signal
    /// rather than polling `Task.yield()`. Underscore-prefixed — test-only
    /// surface, not stable API. No-op when no revert is in flight.
    func _waitForRevert() async {
        await revertTask?.value
    }
}
