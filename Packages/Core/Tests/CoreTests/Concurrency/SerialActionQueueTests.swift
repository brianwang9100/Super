import Testing
@testable import Core

/// Exercises complete-action ordering across suspension and synchronous callbacks.
@Suite("SerialActionQueue")
@MainActor
struct SerialActionQueueTests {
    @Test("a later synchronous transition waits for an earlier suspended commit")
    func suspendedCommitPrecedesSynchronousAction() async {
        let queue = SerialActionQueue()
        let entered = SleepGate()
        let release = SleepGate()
        var trace: [String] = []
        var destination = "initial"
        let first = queue.enqueue {
            trace.append("first-start")
            entered.release()
            await release.wait()
            destination = "first"
            trace.append("first-commit")
        }
        await entered.wait()
        let second = queue.enqueueSynchronous {
            destination = "authoritative"
            trace.append("authoritative-commit")
        }

        #expect(second != nil)
        #expect(queue.isBusy)
        #expect(destination == "initial")
        #expect(trace == ["first-start"])
        release.release()
        await first.value
        await second?.value
        #expect(destination == "authoritative")
        #expect(trace == ["first-start", "first-commit", "authoritative-commit"])
        #expect(!queue.isBusy)
    }

    @Test("an idle synchronous action retains the caller's transaction")
    func idleSynchronousActionRunsInline() {
        let queue = SerialActionQueue()
        var didRun = false
        let join = queue.enqueueSynchronous {
            #expect(queue.isBusy)
            didRun = true
        }
        #expect(didRun)
        #expect(join == nil)
        #expect(!queue.isBusy)
    }

    @Test("a synchronous callback queues reentrant work until it returns")
    func synchronousCallbackCannotBeReentered() async {
        let queue = SerialActionQueue()
        var trace: [String] = []
        var child: Task<Void, Never>?
        let parent = queue.enqueueSynchronous {
            trace.append("parent-start")
            child = queue.enqueueSynchronous { trace.append("child") }
            trace.append("parent-end")
        }
        #expect(parent == nil)
        #expect(child != nil)
        #expect(queue.isBusy)
        #expect(trace == ["parent-start", "parent-end"])
        await child?.value
        #expect(trace == ["parent-start", "parent-end", "child"])
        #expect(!queue.isBusy)
    }

    @Test("bootstrap reserves the lane before its task begins and async work stays ordered")
    func reservationAndAsyncOrdering() async {
        let queue = SerialActionQueue()
        let entered = SleepGate()
        let release = SleepGate()
        var trace: [String] = []
        let bootstrap = queue.enqueue {
            trace.append("bootstrap-start")
            entered.release()
            await release.wait()
            trace.append("bootstrap-commit")
        }
        #expect(queue.isBusy)
        let firstNavigation = queue.enqueue { trace.append("first-navigation") }
        let secondNavigation = queue.enqueue { trace.append("second-navigation") }
        await entered.wait()
        #expect(trace == ["bootstrap-start"])
        release.release()
        await bootstrap.value
        await firstNavigation.value
        await secondNavigation.value
        #expect(trace == ["bootstrap-start", "bootstrap-commit", "first-navigation", "second-navigation"])
        #expect(!queue.isBusy)
    }

    @Test("work enqueued by an action survives predecessor cleanup")
    func reentrantEnqueueRetainsBusyLane() async {
        let queue = SerialActionQueue()
        let childEntered = SleepGate()
        let childRelease = SleepGate()
        var trace: [String] = []
        var child: Task<Void, Never>?
        let parent = queue.enqueue {
            trace.append("parent")
            child = queue.enqueue {
                trace.append("child-start")
                childEntered.release()
                await childRelease.wait()
                trace.append("child-commit")
            }
        }
        await parent.value
        await childEntered.wait()
        #expect(queue.isBusy)
        let last = queue.enqueueSynchronous { trace.append("last") }
        #expect(trace == ["parent", "child-start"])
        childRelease.release()
        await child?.value
        await last?.value
        #expect(trace == ["parent", "child-start", "child-commit", "last"])
        #expect(!queue.isBusy)
    }
}
