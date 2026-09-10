import Core
import Foundation

@testable import Bible

/// Consumes scripted outcomes FIFO; an unscripted extra call fails immediately.
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

/// Holds generation until releaseNext; awaitCall establishes an in-flight call
/// before a test injects pause/cancellation.
@MainActor
final class GatedBibleAnnotateGenerator: BibleAnnotateGenerating {
    private(set) var receivedReferences: [RecordReference] = []
    /// Peak concurrent calls; detects overlapping runner loops without polling.
    private(set) var maxInFlight = 0
    private var pending: [CheckedContinuation<BibleAnnotateOutcome, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func generate(reference: RecordReference) async -> BibleAnnotateOutcome {
        receivedReferences.append(reference)
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            maxInFlight = max(maxInFlight, pending.count)
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Returns immediately if a generation is already in flight.
    func awaitCall() async {
        if !pending.isEmpty { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            arrivalWaiters.append(continuation)
        }
    }

    /// Completes the oldest in-flight generation.
    func releaseNext(_ outcome: BibleAnnotateOutcome) {
        guard !pending.isEmpty else {
            fatalError("GatedBibleAnnotateGenerator: releaseNext with no in-flight generate")
        }
        pending.removeFirst().resume(returning: outcome)
    }

    var inFlightCount: Int { pending.count }
}

/// Gates model resolution so tests can cancel during asynchronous run setup.
@MainActor
final class GatedModelID {
    private var pending: CheckedContinuation<String, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func value() async -> String {
        await withCheckedContinuation { continuation in
            pending = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    func awaitCall() async {
        if pending != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            arrival = continuation
        }
    }

    func release(_ id: String) {
        pending?.resume(returning: id)
        pending = nil
    }
}
