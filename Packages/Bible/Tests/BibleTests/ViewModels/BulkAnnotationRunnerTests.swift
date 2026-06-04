import Core
import Foundation
import Testing

@testable import Bible

/// Engine tests for the LLM-backed `BulkAnnotationRunner`, driven against an
/// in-memory ledger and a scripted/gated `BibleAnnotateGenerating`. The runner's
/// `_waitUntilIdle()` test seam awaits the work loop + all issued ledger writes,
/// so every assertion is deterministic with no sleeps.
@MainActor
@Suite struct BulkAnnotationRunnerTests {

    // MARK: - Fixtures

    private func makeRunner(
        generator: any BibleAnnotateGenerating,
        maxAttempts: Int = 3,
        breaker: Int = 5
    ) throws -> (BulkAnnotationRunner, GRDBBulkAnnotationLedger) {
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            catalog: .standard,
            translation: .web,
            clock: FixedClock(),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "model-x" },
            maxAttemptsPerUnit: maxAttempts,
            consecutiveFailureLimit: breaker
        )
        return (runner, ledger)
    }

    private func oneBookPlan(
        _ bookID: String = "ROM",
        _ name: String = "Romans",
        chapters: [Int]
    ) -> BulkRunPlan {
        BulkRunPlan(books: [BulkRunPlan.Book(bookID: bookID, name: name, chapters: chapters)])
    }

    /// The single run's units in ordinal order (fails the test if there isn't
    /// exactly one run).
    private func loadUnits(_ ledger: GRDBBulkAnnotationLedger) async throws -> [BulkAnnotationRunUnitRecord] {
        let run = try #require(try await ledger.run(id: "id-1"))
        return try await ledger.units(runId: run.id)
    }

    // MARK: - Happy path

    @Test func happyPathCompletesEveryUnit() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 5),
            .success(annotationCount: 7),
            .success(annotationCount: 9),
        ])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1, 2, 3]))
        await runner._waitUntilIdle()

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(run.completedAt != nil)
        #expect(run.modelId == "model-x")

        let units = try await ledger.units(runId: run.id)
        #expect(units.count == 3)
        for unit in units {
            #expect(unit.state == .done)
        }
        #expect(units[0].producedCount == 5)
        #expect(units[1].producedCount == 7)
        #expect(units[2].producedCount == 9)
        #expect(runner.snapshot?.producedCount == 21)
        #expect(runner.snapshot?.isRunning == false)
    }

    // MARK: - Per-unit retry

    @Test func retryableFailureRetriesSameUnitThenSucceeds() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "blip", classification: .retryable),
            .success(annotationCount: 4),
        ])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1]))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units.count == 1)
        #expect(units[0].state == .done)
        #expect(units[0].attemptCount == 2)
        #expect(units[0].producedCount == 4)

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

    @Test func retryableFailureExhaustsAttemptsThenFailsButRunCompletes() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "down", classification: .retryable),
            .failure(message: "down", classification: .retryable),
        ])
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 2)

        runner.start(oneBookPlan(chapters: [1]))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units[0].state == .failed)
        #expect(units[0].attemptCount == 2)
        #expect(units[0].errorMessage == "down")

        // A failed unit is terminal, so the run still completes.
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(run.haltReason == nil)
    }

    // MARK: - Circuit breaker

    @Test func fatalAuthHaltsRunAndSparesRemainingUnits() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "401", classification: .fatalAuth),
        ])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1, 2]))
        await runner._waitUntilIdle()

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .failed)
        #expect(run.haltReason == .auth)
        #expect(run.completedAt != nil)

        let units = try await ledger.units(runId: run.id)
        #expect(units[0].state == .failed)
        #expect(units[1].state == .queued)  // never attempted — wallet protection
        #expect(generator.receivedReferences.count == 1)
        #expect(runner.snapshot?.isRunning == false)
    }

    @Test func fatalQuotaHaltsWithQuotaReason() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "429", classification: .fatalQuota),
        ])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1, 2]))
        await runner._waitUntilIdle()

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .failed)
        #expect(run.haltReason == .quota)
    }

    @Test func consecutiveFailuresTripBreaker() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "x", classification: .retryable),
            .failure(message: "x", classification: .retryable),
            .failure(message: "x", classification: .retryable),
        ])
        // One attempt per unit, breaker at 3 → the 3rd failed unit trips it.
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1, breaker: 3)

        runner.start(oneBookPlan(chapters: [1, 2, 3, 4]))
        await runner._waitUntilIdle()

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .failed)
        #expect(run.haltReason == .consecutiveFailures)

        let units = try await ledger.units(runId: run.id)
        #expect(units[3].state == .queued)  // breaker fired before the 4th
        #expect(generator.receivedReferences.count == 3)
    }

    // MARK: - Manual retry

    @Test func manualRetryRevivesFailedUnitAndCompletesRun() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "boom", classification: .retryable),
        ])
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1)

        runner.start(oneBookPlan(chapters: [1]))
        await runner._waitUntilIdle()

        var units = try await loadUnits(ledger)
        #expect(units[0].state == .failed)

        generator.enqueue(.success(annotationCount: 3))
        runner.retry(ChapterRef(bookID: "ROM", number: 1))
        await runner._waitUntilIdle()

        units = try await loadUnits(ledger)
        #expect(units[0].state == .done)
        #expect(units[0].producedCount == 3)
        #expect(units[0].attemptCount == 1)  // reset to 0 on revive, then +1

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(run.haltReason == nil)
    }

    @Test func retryAllFailedRevivesEveryFailedUnit() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "a", classification: .retryable),
            .failure(message: "b", classification: .retryable),
        ])
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1)

        runner.start(oneBookPlan(chapters: [1, 2]))
        await runner._waitUntilIdle()

        var units = try await loadUnits(ledger)
        #expect(units[0].state == .failed)
        #expect(units[1].state == .failed)

        generator.enqueue(.success(annotationCount: 2))
        generator.enqueue(.success(annotationCount: 6))
        runner.retryAllFailed()
        await runner._waitUntilIdle()

        units = try await loadUnits(ledger)
        #expect(units[0].state == .done)
        #expect(units[1].state == .done)

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

    /// Retrying a failed unit while another unit is still generating must NOT
    /// spawn a second concurrent work loop (which would double-generate and
    /// corrupt the breaker) — the live loop picks the revived unit up instead.
    @Test func retryWhileGeneratingDoesNotStartSecondLoop() async throws {
        let generator = GatedBibleAnnotateGenerator()
        // One attempt per unit so chapter 1 fails immediately on a retryable.
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1)

        runner.start(oneBookPlan(chapters: [1, 2, 3]))

        // Chapter 1 fails; the loop advances to chapter 2 and holds it in flight.
        await generator.awaitCall()
        generator.releaseNext(.failure(message: "down", classification: .retryable))
        await generator.awaitCall()  // chapter 2 now generating

        // Revive chapter 1 while chapter 2 is mid-flight, then drain one unit at
        // a time. A second (buggy) work loop would drive a concurrent generate
        // for the revived unit while chapter 2 is still in flight.
        runner.retry(ChapterRef(bookID: "ROM", number: 1))
        generator.releaseNext(.success(annotationCount: 2))  // chapter 2 done
        await generator.awaitCall()                          // revived chapter 1
        generator.releaseNext(.success(annotationCount: 1))  // chapter 1 done
        await generator.awaitCall()                          // chapter 3
        generator.releaseNext(.success(annotationCount: 3))  // chapter 3 done
        await runner._waitUntilIdle()

        // The single-flight guard held: a generation was never in flight more
        // than once at a time (the passive high-water mark proves it without
        // polling), and no chapter was generated twice.
        #expect(generator.maxInFlight == 1)
        #expect(generator.receivedReferences.count == 4)
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        let units = try await ledger.units(runId: run.id)
        for unit in units {
            #expect(unit.state == .done)
        }
    }

    // MARK: - Cancel (gated, mid-flight)

    @Test func cancelTearsDownRunAndClearsSnapshot() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1, 2]))
        await generator.awaitCall()  // first unit in flight
        runner.cancel()
        generator.releaseNext(.success(annotationCount: 5))  // resolve the in-flight call
        await runner._waitUntilIdle()

        #expect(runner.snapshot == nil)
        let completed = try await ledger.completedRuns()
        #expect(completed.count == 1)
        #expect(completed.first?.status == .cancelled)
        #expect(completed.first?.completedAt != nil)
    }

    /// Cancelling while the engine is suspended resolving the active model (at
    /// run kickoff, before the run row is written) must leave the ledger empty —
    /// no phantom `.cancelled` row and no resurrected run.
    @Test func cancelDuringModelIDResolutionLeavesNoLedgerRow() async throws {
        let modelGate = GatedModelID()
        let generator = ScriptedBibleAnnotateGenerator()  // must never be called
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            clock: FixedClock(),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { await modelGate.value() }
        )

        runner.start(oneBookPlan(chapters: [1]))
        await modelGate.awaitCall()  // suspended in persistThenRun at currentModelID()
        runner.cancel()
        modelGate.release("model-x")  // resume; the identity guard must bail
        await runner._waitUntilIdle()

        #expect(runner.snapshot == nil)
        #expect(try await ledger.run(id: "id-1") == nil)
        let completed = try await ledger.completedRuns()
        #expect(completed.isEmpty)
        #expect(generator.receivedReferences.isEmpty)
    }

    // MARK: - Pause / resume (gated, mid-flight)

    @Test func pauseMidFlightParksRunThenResumeCompletes() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1, 2]))
        await generator.awaitCall()  // unit 0 in flight
        runner.togglePause()
        generator.releaseNext(.success(annotationCount: 5))  // discarded; unit re-queued
        await runner._waitUntilIdle()

        #expect(runner.snapshot?.isRunning == false)
        let parked = try #require(try await ledger.activeRun())
        #expect(parked.status == .paused)
        let unitsWhilePaused = try await ledger.units(runId: parked.id)
        #expect(unitsWhilePaused[0].state == .queued)  // returned to the queue

        // Resume — re-generates unit 0, then unit 1.
        runner.togglePause()
        await generator.awaitCall()
        generator.releaseNext(.success(annotationCount: 5))
        await generator.awaitCall()
        generator.releaseNext(.success(annotationCount: 7))
        await runner._waitUntilIdle()

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        let units = try await ledger.units(runId: run.id)
        #expect(units[0].state == .done)
        #expect(units[1].state == .done)
    }

    // MARK: - Restore on launch

    @Test func restoreResumesRunningRunAndResetsInFlightUnit() async throws {
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let now = Date(timeIntervalSince1970: 100)
        let run = BulkAnnotationRunRecord(
            id: "run-A", status: .running, modelId: "model-x", createdAt: now, updatedAt: now
        )
        let units = [
            BulkAnnotationRunUnitRecord(
                id: "u0", runId: "run-A", ordinal: 0, kind: .chapter, bookId: "ROM",
                bookName: "Romans", chapterNumber: 1, state: .done, producedCount: 3, updatedAt: now
            ),
            BulkAnnotationRunUnitRecord(
                id: "u1", runId: "run-A", ordinal: 1, kind: .chapter, bookId: "ROM",
                bookName: "Romans", chapterNumber: 2, state: .generating, updatedAt: now
            ),
            BulkAnnotationRunUnitRecord(
                id: "u2", runId: "run-A", ordinal: 2, kind: .chapter, bookId: "ROM",
                bookName: "Romans", chapterNumber: 3, state: .queued, updatedAt: now
            ),
        ]
        try await ledger.createRun(run, units: units)

        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 8),  // u1 (reset from generating)
            .success(annotationCount: 6),  // u2
        ])
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            clock: FixedClock(),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "model-x" }
        )

        await runner.restore()
        await runner._waitUntilIdle()

        let restored = try #require(try await ledger.run(id: "run-A"))
        #expect(restored.status == .completed)
        let final = try await ledger.units(runId: "run-A")
        #expect(final[1].state == .done)
        #expect(final[1].producedCount == 8)
        #expect(final[2].state == .done)
    }

    @Test func restorePausedRunStaysParked() async throws {
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let now = Date(timeIntervalSince1970: 100)
        let run = BulkAnnotationRunRecord(
            id: "run-P", status: .paused, modelId: "model-x", createdAt: now, updatedAt: now
        )
        let units = [
            BulkAnnotationRunUnitRecord(
                id: "u0", runId: "run-P", ordinal: 0, kind: .chapter, bookId: "ROM",
                bookName: "Romans", chapterNumber: 1, state: .queued, updatedAt: now
            )
        ]
        try await ledger.createRun(run, units: units)

        let generator = ScriptedBibleAnnotateGenerator()  // must not be called
        let runner = BulkAnnotationRunner(ledger: ledger, generator: generator)

        await runner.restore()
        await runner._waitUntilIdle()

        #expect(runner.snapshot?.isRunning == false)
        let still = try #require(try await ledger.run(id: "run-P"))
        #expect(still.status == .paused)
        #expect(generator.receivedReferences.isEmpty)
    }

    // MARK: - Reference shape

    @Test func generatedReferenceMatchesPerTargetShape() async throws {
        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 1)])
        let (runner, _) = try makeRunner(generator: generator)

        runner.start(oneBookPlan("ROM", "Romans", chapters: [8]))
        await runner._waitUntilIdle()

        let reference = try #require(generator.receivedReferences.first)
        #expect(reference.kind == "chapter")
        #expect(reference.sourceID == "chapter:ROM:8")
        #expect(reference.displayLabel == "Romans 8")
        #expect(reference.citation == "Romans 8 (WEB)")
        #expect(reference.snapshot == "")
        #expect(reference.appletID == "bible")
    }
}
