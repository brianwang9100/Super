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

    // MARK: - handle

    @Test func handleDrainsTheActiveRunToCompletion() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 3),
            .success(annotationCount: 4),
        ])
        let (scheduler, runner, ledger, system) = try make(generator: generator)
        runner.start(plan([1, 2]))

        let task = FakeTask()
        await scheduler.handle(task)
        await runner._waitUntilIdle()

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(task.completedSuccess == true)
        // Nothing left to do → no reschedule.
        #expect(system.submitted.isEmpty)
    }

    @Test func expirationStopsAfterTheCurrentUnitAndReschedules() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (scheduler, runner, ledger, system) = try make(generator: generator)
        runner.start(plan([1, 2, 3]))

        let task = FakeTask()
        let handling = Task { await scheduler.handle(task) }

        await generator.awaitCall()                       // unit 1 in flight
        generator.releaseNext(.success(annotationCount: 2))  // unit 1 done, unit 2 starts
        await generator.awaitCall()                       // unit 2 in flight
        task.expire()                                     // BGTask out of time
        generator.releaseNext(.success(annotationCount: 3))  // unit 2's result still saved, then loop stops

        await handling.value
        await runner._waitUntilIdle()

        let units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .done)
        #expect(units[1].state == .done)                  // in-flight unit's result kept — not wasted
        #expect(units[2].state == .queued)                // never attempted

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .running)                   // still active, parked for resume
        #expect(task.completedSuccess == false)           // cut short by expiration
        #expect(system.submitted.count == 1)              // rescheduled to continue later
    }

    // MARK: - Foreground resume

    @Test func applicationDidBecomeActiveResumesABackgroundStoppedRun() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (scheduler, runner, ledger, _) = try make(generator: generator)
        runner.start(plan([1, 2]))

        // A background task stops the loop after unit 1.
        await generator.awaitCall()
        runner.requestBackgroundStop()
        generator.releaseNext(.success(annotationCount: 1))
        await runner._waitUntilIdle()

        var units = try await ledger.units(runId: "id-1")
        #expect(units[0].state == .done)
        #expect(units[1].state == .queued)
        let parked = try #require(try await ledger.run(id: "id-1"))
        #expect(parked.status == .running)                // parked, still active

        // Foreground returns → resume drains the rest.
        scheduler.applicationDidBecomeActive()
        await generator.awaitCall()
        generator.releaseNext(.success(annotationCount: 2))
        await runner._waitUntilIdle()

        units = try await ledger.units(runId: "id-1")
        #expect(units[1].state == .done)
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }
}
