import Core
import Foundation
import GRDB
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
        breaker: Int = 5,
        seedAnnotatedChapters: [Int] = [],
        seedAnnotatedBook: Bool = false
    ) throws -> (BulkAnnotationRunner, GRDBBulkAnnotationLedger) {
        // One in-memory DB backs both the ledger and the annotation repository so
        // a seeded slot the runner reads is the one the ledger persists against.
        let database = try BibleDatabase.makeInMemory()
        let ledger = GRDBBulkAnnotationLedger(database: database)
        try seedAnnotations(into: database, chapters: seedAnnotatedChapters, book: seedAnnotatedBook)
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            annotationRepository: GRDBBibleAnnotationRepository(database: database),
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

    /// A repository over a throwaway empty DB — for lifecycle tests that never
    /// touch annotation content, so preserve mode's skip check always reads
    /// "slot empty" and never skips.
    private func emptyAnnotationRepository() throws -> GRDBBibleAnnotationRepository {
        GRDBBibleAnnotationRepository(database: try BibleDatabase.makeInMemory())
    }

    /// Pre-seed Romans chapter- and/or book-level annotations directly so a
    /// preserve-mode run finds those slots occupied and skips them.
    private func seedAnnotations(into database: BibleDatabase, chapters: [Int], book: Bool) throws {
        func record(target: BibleAnnotationTarget, chapter: Int?) -> BibleAnnotationRecord {
            BibleAnnotationRecord(
                id: "seed-ROM-\(chapter.map(String.init) ?? "book")",
                target: target, bookId: "ROM", chapterNumber: chapter,
                verseStart: nil, verseEnd: nil, category: .summary,
                title: "Seed", body: "Seed", source: .user, modelId: "seed",
                createdAt: Date(timeIntervalSince1970: 0)
            )
        }
        try database.queue.write { db in
            for chapter in chapters { try record(target: .chapter, chapter: chapter).insert(db) }
            if book { try record(target: .book, chapter: nil).insert(db) }
        }
    }

    private func oneBookPlan(
        _ bookID: String = "ROM",
        _ name: String = "Romans",
        chapters: [Int],
        includesBookLevel: Bool = false,
        overwriteExisting: Bool = false
    ) -> BulkRunPlan {
        BulkRunPlan(
            books: [
                BulkRunPlan.Book(
                    bookID: bookID,
                    name: name,
                    chapters: chapters,
                    includesBookLevel: includesBookLevel
                )
            ],
            overwriteExisting: overwriteExisting
        )
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
        // The completed run clears the active slot so the hub returns to idle
        // (the Generate CTA comes back); it now surfaces in the finished list.
        #expect(runner.snapshot == nil)
    }

    // MARK: - Whole-book selection (book-level prologue unit)

    @Test func wholeBookSelectionEnqueuesABookPrologueAheadOfChapters() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 3),  // book-level
            .success(annotationCount: 5),  // chapter 1
            .success(annotationCount: 6),  // chapter 2
        ])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1, 2], includesBookLevel: true))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units.count == 3)
        // The book-level unit sorts first (ordinal 0) and carries no chapter.
        #expect(units[0].kind == .bookPrologue)
        #expect(units[0].chapterNumber == nil)
        #expect(units[1].kind == .chapter)
        #expect(units[1].chapterNumber == 1)
        #expect(units[2].kind == .chapter)
        #expect(units[2].chapterNumber == 2)
        for unit in units { #expect(unit.state == .done) }

        // The first generation targets the whole book, matching the single-shot
        // book reference convention the dispatcher prompt expects.
        let first = try #require(generator.receivedReferences.first)
        #expect(first.kind == "book")
        #expect(first.sourceID == "book:ROM")
        #expect(first.displayLabel == "Romans")
        #expect(first.citation == "Romans (WEB)")

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

    // MARK: - Preserve vs overwrite (skip already-annotated slots)

    /// Preserve mode (the default): a chapter whose slot is already annotated is
    /// skipped before generating — no LLM call — while a fresh chapter generates.
    @Test func preserveSkipsAlreadyAnnotatedChapterWithoutGenerating() async throws {
        // Only chapter 2 should reach the generator; scripting exactly one
        // success means a stray call on the skipped chapter would trap (strict
        // double) rather than silently pass.
        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 7)])
        let (runner, ledger) = try makeRunner(generator: generator, seedAnnotatedChapters: [1])

        runner.start(oneBookPlan(chapters: [1, 2]))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units[0].chapterNumber == 1)
        #expect(units[0].state == .skipped)
        #expect(units[0].producedCount == 0)
        #expect(units[1].chapterNumber == 2)
        #expect(units[1].state == .done)
        #expect(units[1].producedCount == 7)

        // The model saw only the un-annotated chapter.
        #expect(generator.receivedReferences.count == 1)
        #expect(generator.receivedReferences.first?.sourceID == "chapter:ROM:2")

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

    /// Overwrite mode regenerates an already-annotated chapter — both chapters
    /// reach the generator, none are skipped.
    @Test func overwriteRegeneratesAlreadyAnnotatedChapter() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 4),
            .success(annotationCount: 5),
        ])
        let (runner, ledger) = try makeRunner(generator: generator, seedAnnotatedChapters: [1])

        runner.start(oneBookPlan(chapters: [1, 2], overwriteExisting: true))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units.allSatisfy { $0.state == .done })
        #expect(generator.receivedReferences.count == 2)
    }

    /// A run whose every slot is already annotated completes with all units
    /// skipped, never calling the generator and never tripping the circuit
    /// breaker (a skip is not a failure).
    @Test func allSkippedRunCompletesWithoutTrippingBreaker() async throws {
        let generator = ScriptedBibleAnnotateGenerator()  // must never be called
        let (runner, ledger) = try makeRunner(
            generator: generator, breaker: 1, seedAnnotatedChapters: [1, 2, 3]
        )

        runner.start(oneBookPlan(chapters: [1, 2, 3]))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units.allSatisfy { $0.state == .skipped })
        #expect(generator.receivedReferences.isEmpty)

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)        // not .failed — skips don't halt
        #expect(run.haltReason == nil)
    }

    /// The book-prologue unit is skipped too when a book-level annotation already
    /// exists, while the book's chapters still generate.
    @Test func preserveSkipsAlreadyAnnotatedBookPrologue() async throws {
        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 6)])  // chapter 1 only
        let (runner, ledger) = try makeRunner(generator: generator, seedAnnotatedBook: true)

        runner.start(oneBookPlan(chapters: [1], includesBookLevel: true))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units[0].kind == .bookPrologue)
        #expect(units[0].state == .skipped)
        #expect(units[1].kind == .chapter)
        #expect(units[1].state == .done)
        #expect(generator.receivedReferences.count == 1)
        #expect(generator.receivedReferences.first?.kind == "chapter")
    }

    /// An indeterminate existence read in preserve mode must fail the unit
    /// rather than silently overwriting — the generator is never called.
    @Test func readFailureInPreserveModeFailsTheUnitWithoutOverwriting() async throws {
        let generator = ScriptedBibleAnnotateGenerator()  // must never be called
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            annotationRepository: ThrowingAnnotationRepository(),
            clock: FixedClock(),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "model-x" },
            maxAttemptsPerUnit: 1
        )

        runner.start(oneBookPlan(chapters: [1]))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units[0].state == .failed)
        #expect(units[0].errorMessage != nil)
        #expect(generator.receivedReferences.isEmpty)  // never regenerated/overwrote
    }

    /// The per-run flag is persisted on the run record so a relaunch/resume
    /// honors the choice made at kickoff.
    @Test func overwriteFlagIsPersistedOnTheRunRecord() async throws {
        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 1)])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1], overwriteExisting: true))
        await runner._waitUntilIdle()

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.overwriteExisting == true)
    }

    @Test("chapter references carry the verbatim verse text; book references don't")
    func referencesCarryGroundingText() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 3),  // book-level
            .success(annotationCount: 5),  // chapter 1
        ])
        let (runner, _) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1], includesBookLevel: true))
        await runner._waitUntilIdle()

        let book = try #require(generator.receivedReferences.first { $0.kind == "book" })
        // Whole-book target stays text-light — the full book would be enormous.
        #expect(book.snapshot.isEmpty)

        let chapter = try #require(generator.receivedReferences.first { $0.kind == "chapter" })
        // The chapter reference grounds the model in the real WEB text, numbered.
        #expect(!chapter.snapshot.isEmpty)
        #expect(chapter.snapshot.hasPrefix("1. "))
        #expect(chapter.snapshot.contains("\n2. "))
    }

    @Test func chapterOnlySelectionEnqueuesNoBookPrologue() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 5),
            .success(annotationCount: 6),
        ])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1, 2], includesBookLevel: false))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units.count == 2)
        for unit in units { #expect(unit.kind == .chapter) }
        for reference in generator.receivedReferences { #expect(reference.kind == "chapter") }
    }

    @Test func failedBookLevelUnitIsRevivedByResume() async throws {
        // The book-level unit (ordinal 0) fails terminally; its chapter succeeds.
        // The book unit isn't shown in the live progress grid, so its recovery
        // path runs through the finished-run list — `resume` must revive it
        // kind-agnostically, not just chapter units.
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "boom", classification: .retryable),  // book-level
            .success(annotationCount: 5),                           // chapter 1
        ])
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1)

        runner.start(oneBookPlan(chapters: [1], includesBookLevel: true))
        await runner._waitUntilIdle()

        var units = try await loadUnits(ledger)
        #expect(units.count == 2)
        // The run completed with one failed (book) and one done (chapter) unit.
        #expect(units[0].kind == .bookPrologue)
        #expect(units[0].state == .failed)
        #expect(units[1].kind == .chapter)
        #expect(units[1].state == .done)
        var run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)

        // Retry from the finished list revives the failed book unit and re-runs
        // it to a clean completion.
        generator.enqueue(.success(annotationCount: 3))
        runner.resume(runID: "id-1")
        await runner._waitUntilIdle()

        units = try await loadUnits(ledger)
        #expect(units[0].kind == .bookPrologue)
        #expect(units[0].state == .done)
        #expect(units[0].producedCount == 3)
        run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(run.haltReason == nil)
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
        #expect(runner.snapshot == nil)  // halted run clears the active slot too
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

    // MARK: - Manual retry (while the run is still active)

    /// `retryAllFailed()` revives every `.failed` unit on a *still-running* run —
    /// the per-chapter Retry the progress screen offers while a later unit holds
    /// the run open. (Reviving a finished run instead goes through `resume`.)
    @Test func retryAllFailedRevivesFailedUnitsOnAnActiveRun() async throws {
        let generator = GatedBibleAnnotateGenerator()
        // One attempt per unit so a retryable fails the unit immediately; a high
        // breaker so two failures in a row don't halt the run.
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1, breaker: 99)

        runner.start(oneBookPlan(chapters: [1, 2, 3]))

        // Chapters 1 and 2 fail; chapter 3 is held in flight, keeping the run
        // active with two `.failed` units present.
        await generator.awaitCall()
        generator.releaseNext(.failure(message: "a", classification: .retryable))
        await generator.awaitCall()
        generator.releaseNext(.failure(message: "b", classification: .retryable))
        await generator.awaitCall()  // chapter 3 now generating (held)

        // Revive both failed units while the run is still going.
        runner.retryAllFailed()

        generator.releaseNext(.success(annotationCount: 9))  // chapter 3 done
        await generator.awaitCall()
        generator.releaseNext(.success(annotationCount: 2))  // revived chapter 1
        await generator.awaitCall()
        generator.releaseNext(.success(annotationCount: 6))  // revived chapter 2
        await runner._waitUntilIdle()

        let units = try await ledger.units(runId: "id-1")
        #expect(units.allSatisfy { $0.state == .done })
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(runner.snapshot == nil)  // completed → active slot cleared
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
            annotationRepository: try emptyAnnotationRepository(),
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
            annotationRepository: try emptyAnnotationRepository(),
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

    @Test func runInBackgroundResumesARunLoadedFromTheLedger() async throws {
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let now = Date(timeIntervalSince1970: 100)
        let run = BulkAnnotationRunRecord(
            id: "run-B", status: .running, modelId: "model-x", createdAt: now, updatedAt: now
        )
        let units = [
            BulkAnnotationRunUnitRecord(
                id: "u0", runId: "run-B", ordinal: 0, kind: .chapter, bookId: "ROM",
                bookName: "Romans", chapterNumber: 1, state: .done, producedCount: 3, updatedAt: now
            ),
            BulkAnnotationRunUnitRecord(
                id: "u1", runId: "run-B", ordinal: 1, kind: .chapter, bookId: "ROM",
                bookName: "Romans", chapterNumber: 2, state: .queued, updatedAt: now
            ),
        ]
        try await ledger.createRun(run, units: units)

        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 6)])
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            annotationRepository: try emptyAnnotationRepository(),
            clock: FixedClock(),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "model-x" }
        )

        // A fresh runner with nothing in memory loads + drains the active run.
        await runner.runInBackground()
        await runner._waitUntilIdle()

        let finished = try #require(try await ledger.run(id: "run-B"))
        #expect(finished.status == .completed)
        let final = try await ledger.units(runId: "run-B")
        #expect(final[1].state == .done)
        #expect(final[1].producedCount == 6)
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
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            annotationRepository: try emptyAnnotationRepository()
        )

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
        // A chapter reference now grounds the generator in the exact verse text
        // (see `referencesCarryGroundingText`), so the snapshot is populated.
        #expect(reference.snapshot.hasPrefix("1. "))
        #expect(reference.appletID == "bible")
    }

    // MARK: - Finished-run lifecycle

    /// Retrying a finished run that left a failed unit revives it and drives the
    /// run back to completion — and clears the active slot again when done.
    @Test func resumeRevivesFailedRunAndCompletes() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "boom", classification: .retryable),
        ])
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1)

        runner.start(oneBookPlan(chapters: [1]))
        await runner._waitUntilIdle()

        // The unit failed but the run completed (a failed unit is terminal), and
        // the active slot cleared — the run is now in the finished list.
        var units = try await loadUnits(ledger)
        #expect(units[0].state == .failed)
        #expect(runner.snapshot == nil)
        var run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(run.completedAt != nil)

        // Retry from the finished list → revive + re-run to a clean completion.
        generator.enqueue(.success(annotationCount: 4))
        runner.resume(runID: "id-1")
        await runner._waitUntilIdle()

        units = try await loadUnits(ledger)
        #expect(units[0].state == .done)
        #expect(units[0].producedCount == 4)
        #expect(units[0].attemptCount == 1)  // reset on revive, then +1

        run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(run.haltReason == nil)
        #expect(runner.snapshot == nil)
    }

    /// Resuming a cleanly-completed run (no failed/queued work) is a no-op — it
    /// stays terminal and the generator is never called again.
    @Test func resumeOnCleanCompletionIsNoOp() async throws {
        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 3)])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1]))
        await runner._waitUntilIdle()
        #expect(generator.receivedReferences.count == 1)

        runner.resume(runID: "id-1")
        await runner._waitUntilIdle()

        #expect(generator.receivedReferences.count == 1)  // not re-driven
        #expect(runner.snapshot == nil)
        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

    /// Dismissing a finished run deletes its ledger row (and cascades its units).
    @Test func dismissFinishedRunDeletesTheRow() async throws {
        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 2)])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1]))
        await runner._waitUntilIdle()
        #expect(try await ledger.run(id: "id-1") != nil)

        runner.dismissFinishedRun(id: "id-1")
        await runner._waitUntilIdle()

        #expect(try await ledger.run(id: "id-1") == nil)
        #expect(try await ledger.units(runId: "id-1").isEmpty)
    }

    /// `restore()` sweeps terminal runs older than the retention window and keeps
    /// recent ones, regardless of whether there's an active run to resume.
    @Test func restoreSweepsRunsOlderThanRetention() async throws {
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = BulkAnnotationRunRecord(
            id: "stale", status: .completed, modelId: "m",
            createdAt: now, updatedAt: now, completedAt: now.addingTimeInterval(-100_000)  // > 24 h ago
        )
        let fresh = BulkAnnotationRunRecord(
            id: "fresh", status: .completed, modelId: "m",
            createdAt: now, updatedAt: now, completedAt: now.addingTimeInterval(-3_600)  // 1 h ago
        )
        try await ledger.createRun(stale, units: [
            BulkAnnotationRunUnitRecord(id: "s0", runId: "stale", ordinal: 0, kind: .chapter,
                                        bookId: "ROM", bookName: "Romans", chapterNumber: 1,
                                        state: .done, updatedAt: now)
        ])
        try await ledger.createRun(fresh, units: [
            BulkAnnotationRunUnitRecord(id: "f0", runId: "fresh", ordinal: 0, kind: .chapter,
                                        bookId: "GAL", bookName: "Galatians", chapterNumber: 1,
                                        state: .done, updatedAt: now)
        ])

        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: ScriptedBibleAnnotateGenerator(),  // no active run → never called
            annotationRepository: try emptyAnnotationRepository(),
            clock: FixedClock(now),
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "m" }
        )
        await runner.restore()
        await runner._waitUntilIdle()

        #expect(try await ledger.run(id: "stale") == nil)   // swept
        #expect(try await ledger.run(id: "fresh") != nil)   // kept
    }

    /// A launch `restore()` must cede to a user-initiated `resume()` already in
    /// flight rather than half-adopting a crash-orphaned active run: `resume`
    /// claims the engine (`isDriving`) synchronously before its async setup, so a
    /// `restore` that doesn't honour that claim would adopt the orphan and call
    /// `startDriver()` — which no-ops against the claim, wedging the run with no
    /// loop. Here `restore` must leave the orphaned `.running` run untouched and
    /// let the resumed run drive to completion as the single active job.
    @Test func restoreCedesToAnInFlightResume() async throws {
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let now = Date(timeIntervalSince1970: 1_000)
        // A crash-orphaned active run (its unit stuck `.generating`).
        try await ledger.createRun(
            BulkAnnotationRunRecord(id: "orphan", status: .running, modelId: "m", createdAt: now, updatedAt: now),
            units: [
                BulkAnnotationRunUnitRecord(id: "o0", runId: "orphan", ordinal: 0, kind: .chapter,
                                            bookId: "GEN", bookName: "Genesis", chapterNumber: 1,
                                            state: .generating, updatedAt: now)
            ]
        )
        // A finished run with a failed unit (the one the user taps Retry on).
        try await ledger.createRun(
            BulkAnnotationRunRecord(id: "fin", status: .completed, modelId: "m",
                                    createdAt: now, updatedAt: now,
                                    completedAt: Date(timeIntervalSince1970: 1_100)),
            units: [
                BulkAnnotationRunUnitRecord(id: "f0", runId: "fin", ordinal: 0, kind: .chapter,
                                            bookId: "ROM", bookName: "Romans", chapterNumber: 1,
                                            state: .failed, attemptCount: 1, errorMessage: "boom", updatedAt: now)
            ]
        )

        let generator = GatedBibleAnnotateGenerator()
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            annotationRepository: try emptyAnnotationRepository(),
            clock: FixedClock(),  // epoch → sweep cutoff is negative, nothing swept
            idGenerator: DeterministicIDGenerator(),
            currentModelID: { "m" }
        )

        // Retry claims the engine synchronously; the racing launch restore must
        // cede instead of adopting "orphan".
        runner.resume(runID: "fin")
        await runner.restore()

        // The resumed run drives its single revived unit to completion.
        await generator.awaitCall()
        generator.releaseNext(.success(annotationCount: 4))
        await runner._waitUntilIdle()

        // Only "fin"'s unit was ever generated — "orphan" was never driven.
        #expect(generator.maxInFlight == 1)
        #expect(generator.receivedReferences.count == 1)

        let fin = try #require(try await ledger.run(id: "fin"))
        #expect(fin.status == .completed)

        // "orphan" is untouched: restore ceded, so its unit was never reset and
        // its run never resumed (a later launch will restore it cleanly).
        let orphan = try #require(try await ledger.run(id: "orphan"))
        #expect(orphan.status == .running)
        let orphanUnits = try await ledger.units(runId: "orphan")
        #expect(orphanUnits[0].state == .generating)
    }
}

/// A repository whose every operation throws — drives the runner's preserve-mode
/// read-failure branch (the existence check can't be resolved).
private struct ThrowingAnnotationRepository: BibleAnnotationRepository {
    struct Boom: Error {}
    func list(target: BibleAnnotationTarget, bookId: String, chapterNumber: Int?, verseStart: Int?, verseEnd: Int?) async throws -> [BibleAnnotationRecord] { throw Boom() }
    func replace(target: BibleAnnotationTarget, bookId: String, chapterNumber: Int?, verseStart: Int?, verseEnd: Int?, inserting records: [BibleAnnotationRecord]) async throws { throw Boom() }
    func hasAnnotation(target: BibleAnnotationTarget, bookId: String, chapterNumber: Int?, verseStart: Int?, verseEnd: Int?) async throws -> Bool { throw Boom() }
    func deleteOne(id: String) async throws { throw Boom() }
    func deleteAll() async throws { throw Boom() }
}
