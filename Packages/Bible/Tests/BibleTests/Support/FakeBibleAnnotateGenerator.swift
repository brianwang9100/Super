import Core
import Foundation

@testable import Bible

/// FIFO test double for `BibleAnnotateGenerating`: each `generate` call pops the
/// next scripted outcome and returns immediately. Strict — `fatalError`s if the
/// runner asks for more generations than were scripted, so a miswired test fails
/// loudly rather than hanging (mirrors Chat's `FakeLLMProvider`).
@MainActor
final class ScriptedBibleAnnotateGenerator: BibleAnnotateGenerating {
    private(set) var receivedReferences: [RecordReference] = []
    private var scripted: [BibleAnnotateOutcome]

    init(_ outcomes: [BibleAnnotateOutcome] = []) {
        scripted = outcomes
    }

    func enqueue(_ outcome: BibleAnnotateOutcome) {
        scripted.append(outcome)
    }

    func generate(reference: RecordReference) async -> BibleAnnotateOutcome {
        receivedReferences.append(reference)
        guard !scripted.isEmpty else {
            fatalError("ScriptedBibleAnnotateGenerator: generate called with no scripted outcome")
        }
        return scripted.removeFirst()
    }
}

/// Manual-release test double: each `generate` call suspends until the test calls
/// `releaseNext(_:)`. Lets a test hold a unit "in flight" and land a
/// pause/cancel mid-generation deterministically, with no sleeps. `awaitCall()`
/// suspends until a generation is actually in flight so the test never races the
/// runner's driver.
@MainActor
final class GatedBibleAnnotateGenerator: BibleAnnotateGenerating {
    private(set) var receivedReferences: [RecordReference] = []
    private var pending: [CheckedContinuation<BibleAnnotateOutcome, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func generate(reference: RecordReference) async -> BibleAnnotateOutcome {
        receivedReferences.append(reference)
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            // Wake anyone awaiting a call now that one is in flight.
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Suspend until at least one `generate` is in flight (returns immediately if
    /// one already is).
    func awaitCall() async {
        if !pending.isEmpty { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            arrivalWaiters.append(continuation)
        }
    }

    /// Complete the oldest in-flight `generate` with `outcome`.
    func releaseNext(_ outcome: BibleAnnotateOutcome) {
        guard !pending.isEmpty else {
            fatalError("GatedBibleAnnotateGenerator: releaseNext with no in-flight generate")
        }
        pending.removeFirst().resume(returning: outcome)
    }

    var inFlightCount: Int { pending.count }
}
