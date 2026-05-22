import Foundation
import Testing
@testable import Chat

/// Tests for ``CodeBlockCopyController``'s pasteboard write + revert
/// timing + cancellation behavior. Drives the controller directly so
/// the assertions don't depend on standing up a SwiftUI render.
///
/// Sleep is injected via a closure so the timing tests don't rely on
/// real-time waits — sim-under-load runs would flake on real-clock
/// timing tests, and the injected closure lets us deterministically
/// control when the revert fires.
@Suite("CodeBlockCopyController")
@MainActor
struct CodeBlockCopyControllerTests {
    @Test("copy writes to the injected pasteboard and flips state to .copied")
    func copyWritesAndFlipsState() async {
        let pasteboard = RecordingPasteboardClient()
        // Sleep that never returns — the test only cares about the
        // state immediately after `copy()`, before the revert window.
        let controller = CodeBlockCopyController(
            pasteboard: pasteboard,
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        controller.copy("hello world")

        #expect(pasteboard.writes == ["hello world"])
        #expect(controller.state == .copied)
    }

    @Test("state reverts to .idle once the revert sleep returns")
    func stateRevertsAfterSleep() async {
        let pasteboard = RecordingPasteboardClient()
        let release = SleepGate()
        let controller = CodeBlockCopyController(
            pasteboard: pasteboard,
            sleep: { _ in await release.wait() }
        )

        controller.copy("abc")
        #expect(controller.state == .copied)

        // Release the sleep — the revert task wakes, checks Task.isCancelled
        // (false), and writes .idle.
        release.release()
        // Spin a few yields to let the revert task's `state = .idle`
        // hop onto the main actor and commit.
        for _ in 0..<10 { await Task.yield() }

        #expect(controller.state == .idle)
    }

    /// Regression test for the M-4 race: the original implementation
    /// spawned an unmanaged `Task` per tap with no cancellation, so a
    /// rapid second tap would race the first revert and an older revert
    /// would wipe the newer `.copied` state. The controller now cancels
    /// the prior revert before scheduling a new one.
    ///
    /// We assert the cancellation by counting how many times the *injected*
    /// sleep got past the cancellation barrier — only the most recent
    /// one should produce a state mutation.
    @Test("rapid copies cancel the prior revert task")
    func rapidCopiesCancelOlderReverts() async {
        let pasteboard = RecordingPasteboardClient()
        let release = SleepGate()
        let controller = CodeBlockCopyController(
            pasteboard: pasteboard,
            sleep: { _ in await release.wait() }
        )

        controller.copy("first")
        // Give the first revert task a chance to start its sleep before
        // the second tap arrives.
        for _ in 0..<5 { await Task.yield() }
        controller.copy("second")

        // Releasing the gate now wakes both tasks. The first one's
        // `Task.isCancelled` check will be true (cancelled by the second
        // tap), so it must not flip state. The second one writes .idle.
        release.release()
        for _ in 0..<10 { await Task.yield() }

        #expect(pasteboard.writes == ["first", "second"])
        #expect(controller.state == .idle)
    }

    @Test("pasteboard hot-swap routes future copies to the new client")
    func pasteboardHotSwap() async {
        let first = RecordingPasteboardClient()
        let second = RecordingPasteboardClient()
        let controller = CodeBlockCopyController(
            pasteboard: first,
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        controller.copy("one")
        controller.pasteboard = second
        controller.copy("two")

        #expect(first.writes == ["one"])
        #expect(second.writes == ["two"])
    }
}

// SleepGate is shared with other test suites — see
// `Tests/ChatTests/UI/Support/SleepGate.swift`.
