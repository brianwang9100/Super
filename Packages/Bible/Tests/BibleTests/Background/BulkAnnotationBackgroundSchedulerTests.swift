import Core
import Foundation
import Testing

@testable import Bible

/// Tests for the background scheduling logic, driven through fakes for the
/// `BGTaskScheduler` / `BGTask` seams so the whole thing runs under `swift test`
/// on macOS with no `BackgroundTasks` framework and no sleeps. The real
/// `System…` adapters are thin pass-throughs verified by the app build +
/// on-device.
@MainActor
@Suite struct BulkAnnotationBackgroundSchedulerTests {

    // MARK: - Fakes

    /// Records the requests the scheduler submits / cancels. Touched only on the
    /// main actor by these tests, so `@unchecked Sendable` over plain storage is
    /// safe.
    private final class FakeTaskScheduling: BulkBackgroundTaskScheduling, @unchecked Sendable {
        private(set) var submitted: [BulkBackgroundTaskRequest] = []
        private(set) var cancelled: [String] = []
        func submit(_ request: BulkBackgroundTaskRequest) throws { submitted.append(request) }
        func cancel(identifier: String) { cancelled.append(identifier) }
    }

    /// Stand-in for a live `BGTask`: captures the expiration handler the
    /// scheduler installs (so a test can fire it) and the completion outcome.
    private final class FakeTask: BulkBackgroundTask {
        var expirationHandler: (() -> Void)?
        private(set) var completedSuccess: Bool?
        func setTaskCompleted(success: Bool) { completedSuccess = success }
        /// Fire the system-installed expiration handler.
        func expire() { expirationHandler?() }
    }

    // MARK: - Fixtures

    private func make(
        generator: any BibleAnnotateGenerating
    ) throws -> (BulkAnnotationBackgroundScheduler, BulkAnnotationRunner, GRDBBulkAnnotationLedger, FakeTaskScheduling) {
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            annotationRepository: GRDBBibleAnnotationRepository(database: try BibleDatabase.makeInMemory()),
            catalog: .standard,
            translation: .web,
            clock: FixedClock(),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "model-x" }
        )
        let system = FakeTaskScheduling()
        let scheduler = BulkAnnotationBackgroundScheduler(runner: runner, ledger: ledger, system: system)
        return (scheduler, runner, ledger, system)
    }

    private func plan(_ chapters: [Int]) -> BulkRunPlan {
        BulkRunPlan(books: [BulkRunPlan.Book(bookID: "ROM", name: "Romans", chapters: chapters)])
    }

    // MARK: - scheduleIfNeeded

    @Test func schedulesANetworkOnlyTaskWhenARunIsActive() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (scheduler, runner, _, system) = try make(generator: generator)
        runner.start(plan([1, 2]))
        await generator.awaitCall()  // a run is now active (unit 1 in flight, run persisted).

        await scheduler.scheduleIfNeeded()

        #expect(system.submitted.count == 1)
        let request = try #require(system.submitted.first)
        #expect(request.identifier == BulkAnnotationBackgroundScheduler.taskIdentifier)
        #expect(request.requiresNetworkConnectivity == true)
        #expect(request.requiresExternalPower == false)
        #expect(system.cancelled.isEmpty)

        // Drain so the gated continuations don't leak.
        generator.releaseNext(.success(annotationCount: 1))
        await generator.awaitCall()
        generator.releaseNext(.success(annotationCount: 1))
        await runner._waitUntilIdle()
    }

    @Test func cancelsTheTaskWhenNoRunIsActive() async throws {
        let (scheduler, _, _, system) = try make(generator: ScriptedBibleAnnotateGenerator())

        await scheduler.scheduleIfNeeded()

        #expect(system.submitted.isEmpty)
        #expect(system.cancelled == [BulkAnnotationBackgroundScheduler.taskIdentifier])
    }

    @Test func doesNotScheduleForAPausedRun() async throws {
        // A paused run is "active" (`activeRun()` returns it) but can't advance in
        // the background — scheduling against it would wake the app repeatedly to
        // do nothing. So a paused run must cancel, not submit.
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let now = Date(timeIntervalSince1970: 100)
        try await ledger.createRun(
            BulkAnnotationRunRecord(
                id: "run-P", status: .paused, modelId: "model-x", createdAt: now, updatedAt: now
            ),
            units: [
                BulkAnnotationRunUnitRecord(
                    id: "p0", runId: "run-P", ordinal: 0, kind: .chapter, bookId: "ROM",
                    bookName: "Romans", chapterNumber: 1, state: .queued, updatedAt: now
                ),
            ]
        )
        let system = FakeTaskScheduling()
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: ScriptedBibleAnnotateGenerator(),
            annotationRepository: GRDBBibleAnnotationRepository(database: try BibleDatabase.makeInMemory()),
            clock: FixedClock(),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "model-x" }
        )
        let scheduler = BulkAnnotationBackgroundScheduler(runner: runner, ledger: ledger, system: system)

        await scheduler.scheduleIfNeeded()

        #expect(system.submitted.isEmpty)
        #expect(system.cancelled == [BulkAnnotationBackgroundScheduler.taskIdentifier])
    }

    // MARK: - handle

    @Test func handleDrivesAndCompletesARunWithNoLiveLoop() async throws {
        // Seed a `.running` run directly in the ledger — no foreground `start()`,
        // so no work loop is live. This is the suspended-app shape: the engine
        // instance exists but its loop has stopped. `handle` must restore the run
        // and drive it to completion itself (not lean on a pre-existing loop).
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let now = Date(timeIntervalSince1970: 100)
        try await ledger.createRun(
            BulkAnnotationRunRecord(
                id: "run-X", status: .running, modelId: "model-x", createdAt: now, updatedAt: now
            ),
            units: [
                BulkAnnotationRunUnitRecord(
                    id: "x0", runId: "run-X", ordinal: 0, kind: .chapter, bookId: "ROM",
                    bookName: "Romans", chapterNumber: 1, state: .queued, updatedAt: now
                ),
                BulkAnnotationRunUnitRecord(
                    id: "x1", runId: "run-X", ordinal: 1, kind: .chapter, bookId: "ROM",
                    bookName: "Romans", chapterNumber: 2, state: .queued, updatedAt: now
                ),
            ]
        )
        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 3),
            .success(annotationCount: 4),
        ])
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            annotationRepository: GRDBBibleAnnotationRepository(database: try BibleDatabase.makeInMemory()),
            clock: FixedClock(),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "model-x" }
        )
        let system = FakeTaskScheduling()
        let scheduler = BulkAnnotationBackgroundScheduler(runner: runner, ledger: ledger, system: system)

        let task = FakeTask()
        await scheduler.handle(task)

        let run = try #require(try await ledger.run(id: "run-X"))
        #expect(run.status == .completed)
        let units = try await ledger.units(runId: "run-X")
        #expect(units.allSatisfy { $0.state == .done })
        #expect(task.completedSuccess == true)
        // Nothing left to do → no reschedule.
        #expect(system.submitted.isEmpty)
    }

    @Test func expirationReQueuesTheInFlightUnitAndReschedules() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (scheduler, runner, ledger, system) = try make(generator: generator)
        runner.start(plan([1, 2, 3]))

        let task = FakeTask()
        let handling = Task { await scheduler.handle(task) }

        await generator.awaitCall()                       // unit 1 in flight
        generator.releaseNext(.success(annotationCount: 2))  // unit 1 done, unit 2 starts
        await generator.awaitCall()                       // unit 2 in flight
        task.expire()                                     // BGTask out of time mid-unit-2
        await handling.value                              // completes WITHOUT waiting out unit 2

        var units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .done)                  // finished before expiration — kept
        #expect(units[1].state == .queued)                // in-flight unit returned to the queue
        #expect(units[2].state == .queued)                // never attempted

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .running)                   // still active, parked for resume
        #expect(task.completedSuccess == false)           // cut short by expiration
        #expect(system.submitted.count == 1)              // rescheduled to continue later

        // Drain the abandoned generate so the gated continuation doesn't leak; its
        // outcome must be discarded (unit 2 stays queued — nothing lands late).
        generator.releaseNext(.success(annotationCount: 3))
        await runner._waitUntilIdle()
        units = try await ledger.units(runId: "id-1")
        #expect(units[1].state == .queued)
    }

    @Test func forceRequeuesInFlightUnitOnExpirationAndCompletesPromptly() async throws {
        // The core P1-5 fix: an expiration that lands *while a unit is still
        // generating* must NOT wait out the (10–60 s) LLM call. It returns the
        // in-flight unit to the queue, completes the task inside iOS's grace
        // window, and discards the abandoned call's eventual outcome.
        let generator = GatedBibleAnnotateGenerator()
        let (scheduler, runner, ledger, system) = try make(generator: generator)
        runner.start(plan([1, 2]))

        let task = FakeTask()
        let handling = Task { await scheduler.handle(task) }

        await generator.awaitCall()   // unit 1 in flight — never released
        task.expire()                 // BGTask out of time mid-generation
        await handling.value          // completes WITHOUT the generate finishing

        // Asserted before releasing the generate: the in-flight unit is back in
        // the queue, the task completed (cut short), and we rescheduled.
        var units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .queued)       // re-queued, not stranded .generating
        #expect(units[1].state == .queued)       // never attempted
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .running)          // parked for resume
        #expect(task.completedSuccess == false)  // cut short by expiration
        #expect(system.submitted.count == 1)     // rescheduled to continue later

        // Now let the abandoned generate return: the loop must discard it with no
        // further ledger write, so nothing lands after the task completed.
        generator.releaseNext(.success(annotationCount: 99))
        await runner._waitUntilIdle()
        units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .queued)       // abandoned outcome discarded
    }

    // MARK: - Foreground resume

    @Test func applicationDidBecomeActiveResumesABackgroundStoppedRun() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (scheduler, runner, ledger, _) = try make(generator: generator)
        runner.start(plan([1, 2]))

        // A background task ran out of time while unit 1 was generating: that unit
        // is returned to the queue (not waited out), and the run stays parked.
        await generator.awaitCall()
        runner.requestExpirationStop()
        generator.releaseNext(.success(annotationCount: 1))  // abandoned outcome — discarded
        await runner._waitUntilIdle()

        var units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .queued)                // in-flight unit re-queued, will re-generate
        #expect(units[1].state == .queued)
        let parked = try #require(try await ledger.run(id: "id-1"))
        #expect(parked.status == .running)                // parked, still active

        // Foreground returns → resume re-generates unit 1, then drains unit 2.
        scheduler.applicationDidBecomeActive()
        await generator.awaitCall()                       // unit 1 re-generates
        generator.releaseNext(.success(annotationCount: 1))
        await generator.awaitCall()                       // unit 2
        generator.releaseNext(.success(annotationCount: 2))
        await runner._waitUntilIdle()

        units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .done)
        #expect(units[1].state == .done)
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

    @Test func foregroundResumeDuringTheAbandonedGenerateStillDrains() async throws {
        // The hazardous interleaving: the user foregrounds the app *while the
        // abandoned LLM call is still in flight* (the driver loop is suspended in
        // `generate`, so the resume's `startDriver` no-ops). When the abandoned
        // call finally returns, the loop must not wedge — it discards the outcome
        // and, because the resume cleared the background-stop, re-generates the
        // re-queued unit on the same loop rather than waiting for a future
        // lifecycle event.
        let generator = GatedBibleAnnotateGenerator()
        let (scheduler, runner, ledger, _) = try make(generator: generator)
        runner.start(plan([1, 2]))

        let task = FakeTask()
        let handling = Task { await scheduler.handle(task) }
        await generator.awaitCall()   // unit 1 in flight
        task.expire()                 // re-queue unit 1, complete the BGTask
        await handling.value

        // Foreground returns BEFORE the abandoned generate resolves.
        scheduler.applicationDidBecomeActive()

        generator.releaseNext(.success(annotationCount: 1))  // abandoned unit-1 outcome — discarded
        await generator.awaitCall()                          // unit 1 re-generates on the live loop
        generator.releaseNext(.success(annotationCount: 1))
        await generator.awaitCall()                          // unit 2
        generator.releaseNext(.success(annotationCount: 2))
        await runner._waitUntilIdle()

        let units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .done)
        #expect(units[1].state == .done)
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)  // not wedged — drained to completion
    }
}
