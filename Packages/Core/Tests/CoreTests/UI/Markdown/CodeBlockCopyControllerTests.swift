import Foundation
import Synchronization
import Testing
@testable import Core

@Suite("CodeBlockCopyController")
@MainActor
struct CodeBlockCopyControllerTests {
    @Test("copy writes to the injected pasteboard and flips state to .copied")
    func copyWritesAndFlipsState() async {
        let pasteboard = RecordingPasteboardClient()
        let release = SleepGate()
        let controller = CodeBlockCopyController(
            pasteboard: pasteboard,
            sleep: { _ in await release.wait() }
        )

        controller.copy("hello world")

        #expect(pasteboard.writes == ["hello world"])
        #expect(controller.state == .copied)
        release.release()
        await controller._waitForRevert()
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

        release.release()
        await controller._waitForRevert()

        #expect(controller.state == .idle)
    }

    @Test("rapid copies cancel the prior revert task")
    func rapidCopiesCancelOlderReverts() async {
        let pasteboard = RecordingPasteboardClient()
        let firstEntered = SleepGate()
        let firstRelease = SleepGate()
        let firstFinished = SleepGate()
        let secondRelease = SleepGate()
        let callCount = Mutex(0)
        let controller = CodeBlockCopyController(
            pasteboard: pasteboard,
            sleep: { _ in
                let index = callCount.withLock { count in
                    defer { count += 1 }
                    return count
                }
                if index == 0 {
                    firstEntered.release()
                    await firstRelease.wait()
                    defer { firstFinished.release() }
                    #expect(Task.isCancelled)
                    try Task.checkCancellation()
                } else {
                    #expect(index == 1)
                    await secondRelease.wait()
                    #expect(!Task.isCancelled)
                }
            }
        )

        controller.copy("first")
        await firstEntered.wait()
        controller.copy("second")
        firstRelease.release()
        await firstFinished.wait()
        #expect(controller.state == .copied)

        secondRelease.release()
        await controller._waitForRevert()
        #expect(pasteboard.writes == ["first", "second"])
        #expect(controller.state == .idle)
    }

    @Test("pasteboard hot-swap routes future copies to the new client")
    func pasteboardHotSwap() async {
        let first = RecordingPasteboardClient()
        let second = RecordingPasteboardClient()
        let release = SleepGate()
        let controller = CodeBlockCopyController(
            pasteboard: first,
            sleep: { _ in await release.wait() }
        )

        controller.copy("one")
        controller.pasteboard = second
        controller.copy("two")

        #expect(first.writes == ["one"])
        #expect(second.writes == ["two"])
        release.release()
        await controller._waitForRevert()
    }
}
