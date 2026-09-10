import Core
import Foundation
import Testing

@testable import Bible

@MainActor
@Suite struct BulkAnnotationBackgroundSchedulerTests {

    // MARK: - Fakes

    /// These tests access storage only on MainActor, making unchecked Sendable safe.
    private final class FakeTaskScheduling: BulkBackgroundTaskScheduling, @unchecked Sendable {
        private(set) var submitted: [BulkBackgroundTaskRequest] = []
        private(set) var cancelled: [String] = []
        func submit(_ request: BulkBackgroundTaskRequest) throws { submitted.append(request) }
        func cancel(identifier: String) { cancelled.append(identifier) }
    }

    private final class FakeTask: BulkBackgroundTask {
        var expirationHandler: (() -> Void)?
        private(set) var completedSuccess: Bool?
        func setTaskCompleted(success: Bool) { completedSuccess = success }
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
        // Paused runs count as active but cannot advance; scheduling them would repeatedly wake for no work.
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
        // Seed a persisted run without a live foreground loop, matching a suspended app.
        // Background handling must restore and drive it independently.
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

        // Drain the abandoned call without leaking its continuation or persisting a late outcome.
        generator.releaseNext(.success(annotationCount: 3))
        await runner._waitUntilIdle()
        units = try await ledger.units(runId: "id-1")
        #expect(units[1].state == .queued)
    }

    @Test func forceRequeuesInFlightUnitOnExpirationAndCompletesPromptly() async throws {
        // Expiration must finish inside the iOS grace window without awaiting the LLM call.
        // Requeue immediately and discard its eventual outcome.
        let generator = GatedBibleAnnotateGenerator()
        let (scheduler, runner, ledger, system) = try make(generator: generator)
        runner.start(plan([1, 2]))

        let task = FakeTask()
        let handling = Task { await scheduler.handle(task) }

        await generator.awaitCall()   // unit 1 in flight — never released
        task.expire()                 // BGTask out of time mid-generation
        await handling.value          // completes WITHOUT the generate finishing

        // Assert before releasing generation to prove expiration requeues immediately.
        var units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .queued)       // re-queued, not stranded .generating
        #expect(units[1].state == .queued)       // never attempted
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .running)          // parked for resume
        #expect(task.completedSuccess == false)  // cut short by expiration
        #expect(system.submitted.count == 1)     // rescheduled to continue later

        // A late abandoned result must not write after background-task completion.
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

        // Expiration requeues the in-flight unit and parks the run.
        await generator.awaitCall()
        runner.requestExpirationStop()
        generator.releaseNext(.success(annotationCount: 1))  // abandoned outcome — discarded
        await runner._waitUntilIdle()

        var units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .queued)                // in-flight unit re-queued, will re-generate
        #expect(units[1].state == .queued)
        let parked = try #require(try await ledger.run(id: "id-1"))
        #expect(parked.status == .running)                // parked, still active

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
        // Foreground resume arrives while the abandoned call still owns the driver.
        // On return, the same loop must discard its result and regenerate the queued unit
        // without waiting for another lifecycle event.
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
