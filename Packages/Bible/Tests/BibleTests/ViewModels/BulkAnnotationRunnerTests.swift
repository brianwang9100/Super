import Core
import Foundation
import GRDB
import Testing

@testable import Bible

@MainActor
@Suite struct BulkAnnotationRunnerTests {

    // MARK: - Fixtures

    private func makeRunner(
        generator: any BibleAnnotateGenerating,
        maxAttempts: Int = 3,
        breaker: Int = 5,
        seedAnnotatedChapters: [Int] = [],
        seedAnnotatedBook: Bool = false,
        seedVerseAnnotatedChapters: [Int] = []
    ) throws -> (BulkAnnotationRunner, GRDBBulkAnnotationLedger) {
        // Share a database so preserve checks see the same annotation state as the run.
        let database = try BibleDatabase.makeInMemory()
        let ledger = GRDBBulkAnnotationLedger(database: database)
        try seedAnnotations(
            into: database, chapters: seedAnnotatedChapters,
            book: seedAnnotatedBook, verseChapters: seedVerseAnnotatedChapters
        )
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

    private func emptyAnnotationRepository() throws -> GRDBBibleAnnotationRepository {
        GRDBBibleAnnotationRepository(database: try BibleDatabase.makeInMemory())
    }

    private func seedAnnotations(
        into database: BibleDatabase, chapters: [Int], book: Bool, verseChapters: [Int] = []
    ) throws {
        func record(target: BibleAnnotationTarget, chapter: Int?) -> BibleAnnotationRecord {
            BibleAnnotationRecord(
                id: "seed-ROM-\(chapter.map(String.init) ?? "book")",
                target: target, bookId: "ROM", chapterNumber: chapter,
                verseStart: nil, verseEnd: nil, summary: "Seed",
                source: .user, modelId: "seed",
                createdAt: Date(timeIntervalSince1970: 0)
            )
        }
        // Any verse annotation satisfies the chapter-wide preserve check.
        func verseRecord(chapter: Int) -> BibleAnnotationRecord {
            BibleAnnotationRecord(
                id: "seed-ROM-\(chapter)-v1", target: .verse, bookId: "ROM",
                chapterNumber: chapter, verseStart: 1, verseEnd: 1, summary: "Seed verse",
                source: .user, modelId: "seed", createdAt: Date(timeIntervalSince1970: 0)
            )
        }
        try database.queue.write { db in
            for chapter in chapters { try record(target: .chapter, chapter: chapter).insert(db) }
            if book { try record(target: .book, chapter: nil).insert(db) }
            for chapter in verseChapters { try verseRecord(chapter: chapter).insert(db) }
        }
    }

    private func oneBookPlan(
        _ bookID: String = "ROM",
        _ name: String = "Romans",
        chapters: [Int],
        includesBookLevel: Bool = false,
        overwriteExisting: Bool = false,
        includesNotableVerses: Bool = false
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
            overwriteExisting: overwriteExisting,
            includesNotableVerses: includesNotableVerses
        )
    }

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
        #expect(units[0].kind == .bookPrologue)
        #expect(units[0].chapterNumber == nil)
        #expect(units[1].kind == .chapter)
        #expect(units[1].chapterNumber == 1)
        #expect(units[2].kind == .chapter)
        #expect(units[2].chapterNumber == 2)
        for unit in units { #expect(unit.state == .done) }

        let first = try #require(generator.receivedReferences.first)
        #expect(first.kind == "book")
        #expect(first.sourceID == "book:ROM")
        #expect(first.displayLabel == "Romans")
        #expect(first.citation == "Romans (WEB)")

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

    // MARK: - Preserve vs overwrite (skip already-annotated slots)

    @Test func preserveSkipsAlreadyAnnotatedChapterWithoutGenerating() async throws {
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

        #expect(generator.receivedReferences.count == 1)
        #expect(generator.receivedReferences.first?.sourceID == "chapter:ROM:2")

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

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

    // MARK: - Notable verses (chapterVerses units)

    @Test func notableVersesEnqueuesAChapterVersesUnitAfterEachChapter() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .success(annotationCount: 1),  // chapter 1 summary
            .success(annotationCount: 5),  // chapter 1 notable verses
            .success(annotationCount: 1),  // chapter 2 summary
            .success(annotationCount: 4),  // chapter 2 notable verses
        ])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1, 2], includesNotableVerses: true))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units.count == 4)
        #expect(units[0].kind == .chapter)
        #expect(units[0].chapterNumber == 1)
        #expect(units[1].kind == .chapterVerses)
        #expect(units[1].chapterNumber == 1)
        #expect(units[2].kind == .chapter)
        #expect(units[2].chapterNumber == 2)
        #expect(units[3].kind == .chapterVerses)
        #expect(units[3].chapterNumber == 2)
        for unit in units { #expect(unit.state == .done) }
        #expect(units[1].producedCount == 5)
        #expect(units[3].producedCount == 4)

        let versesRef = try #require(generator.receivedReferences.first { $0.kind == "chapterVerses" })
        #expect(versesRef.sourceID == "chapterVerses:ROM:1")
        #expect(versesRef.displayLabel == "Romans 1")
        #expect(!versesRef.snapshot.isEmpty)
    }

    @Test func noNotableVersesUnitsWhenToggleOff() async throws {
        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 1)])
        let (runner, ledger) = try makeRunner(generator: generator)

        runner.start(oneBookPlan(chapters: [1], includesNotableVerses: false))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units.count == 1)
        #expect(units.allSatisfy { $0.kind == .chapter })
    }

    @Test func preserveSkipsChapterVersesWhenChapterAlreadyVerseAnnotated() async throws {
        let generator = ScriptedBibleAnnotateGenerator([.success(annotationCount: 1)])
        let (runner, ledger) = try makeRunner(generator: generator, seedVerseAnnotatedChapters: [1])

        runner.start(oneBookPlan(chapters: [1], includesNotableVerses: true))
        await runner._waitUntilIdle()

        let units = try await loadUnits(ledger)
        #expect(units[0].kind == .chapter)
        #expect(units[0].state == .done)         // chapter slot wasn't seeded → generates
        #expect(units[1].kind == .chapterVerses)
        #expect(units[1].state == .skipped)      // chapter already has a verse annotation
        #expect(units[1].producedCount == 0)

        #expect(generator.receivedReferences.count == 1)
        #expect(generator.receivedReferences.first?.kind == "chapter")

        let run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
    }

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
        // Full-book text would make grounding unbounded.
        #expect(book.snapshot.isEmpty)

        let chapter = try #require(generator.receivedReferences.first { $0.kind == "chapter" })
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
        // Book units have no live progress row; finished-run retry must revive every kind.
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "boom", classification: .retryable),  // book-level
            .success(annotationCount: 5),                           // chapter 1
        ])
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1)

        runner.start(oneBookPlan(chapters: [1], includesBookLevel: true))
        await runner._waitUntilIdle()

        var units = try await loadUnits(ledger)
        #expect(units.count == 2)
        #expect(units[0].kind == .bookPrologue)
        #expect(units[0].state == .failed)
        #expect(units[1].kind == .chapter)
        #expect(units[1].state == .done)
        var run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)

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

        // A failed unit is terminal, so a run can complete with failures.
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

    @Test func retryAllFailedRevivesFailedUnitsOnAnActiveRun() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1, breaker: 99)

        runner.start(oneBookPlan(chapters: [1, 2, 3]))

        // Hold chapter 3 in flight so the failed earlier units remain retryable on an active run.
        await generator.awaitCall()
        generator.releaseNext(.failure(message: "a", classification: .retryable))
        await generator.awaitCall()
        generator.releaseNext(.failure(message: "b", classification: .retryable))
        await generator.awaitCall()  // chapter 3 now generating (held)

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

    /// Retry must reuse the live loop; another loop would double-generate and corrupt breaker accounting.
    @Test func retryWhileGeneratingDoesNotStartSecondLoop() async throws {
        let generator = GatedBibleAnnotateGenerator()
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1)

        runner.start(oneBookPlan(chapters: [1, 2, 3]))

        await generator.awaitCall()
        generator.releaseNext(.failure(message: "down", classification: .retryable))
        await generator.awaitCall()  // chapter 2 now generating

        // Retry while chapter 2 is suspended exposes any second concurrent generation loop.
        runner.retry(ChapterRef(bookID: "ROM", number: 1))
        generator.releaseNext(.success(annotationCount: 2))  // chapter 2 done
        await generator.awaitCall()                          // revived chapter 1
        generator.releaseNext(.success(annotationCount: 1))  // chapter 1 done
        await generator.awaitCall()                          // chapter 3
        generator.releaseNext(.success(annotationCount: 3))  // chapter 3 done
        await runner._waitUntilIdle()

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

    /// Cancellation before persistence must leave no phantom run or cancelled ledger row.
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
        #expect(reference.snapshot.hasPrefix("1. "))
        #expect(reference.appletID == "bible")
    }

    // MARK: - Finished-run lifecycle

    @Test func resumeRevivesFailedRunAndCompletes() async throws {
        let generator = ScriptedBibleAnnotateGenerator([
            .failure(message: "boom", classification: .retryable),
        ])
        let (runner, ledger) = try makeRunner(generator: generator, maxAttempts: 1)

        runner.start(oneBookPlan(chapters: [1]))
        await runner._waitUntilIdle()

        var units = try await loadUnits(ledger)
        #expect(units[0].state == .failed)
        #expect(runner.snapshot == nil)
        var run = try #require(try await ledger.run(id: "id-1"))
        #expect(run.status == .completed)
        #expect(run.completedAt != nil)

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

    /// Resume claims isDriving before async setup. Restore must cede or it can adopt
    /// an orphan whose startDriver then no-ops, leaving the run without a loop.
    @Test func restoreCedesToAnInFlightResume() async throws {
        let ledger = GRDBBulkAnnotationLedger(database: try BibleDatabase.makeInMemory())
        let now = Date(timeIntervalSince1970: 1_000)
        try await ledger.createRun(
            BulkAnnotationRunRecord(id: "orphan", status: .running, modelId: "m", createdAt: now, updatedAt: now),
            units: [
                BulkAnnotationRunUnitRecord(id: "o0", runId: "orphan", ordinal: 0, kind: .chapter,
                                            bookId: "GEN", bookName: "Genesis", chapterNumber: 1,
                                            state: .generating, updatedAt: now)
            ]
        )
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

        runner.resume(runID: "fin")
        await runner.restore()

        await generator.awaitCall()
        generator.releaseNext(.success(annotationCount: 4))
        await runner._waitUntilIdle()

        #expect(generator.maxInFlight == 1)
        #expect(generator.receivedReferences.count == 1)

        let fin = try #require(try await ledger.run(id: "fin"))
        #expect(fin.status == .completed)

        let orphan = try #require(try await ledger.run(id: "orphan"))
        #expect(orphan.status == .running)
        let orphanUnits = try await ledger.units(runId: "orphan")
        #expect(orphanUnits[0].state == .generating)
    }
}

private struct ThrowingAnnotationRepository: BibleAnnotationRepository {
    struct Boom: Error {}
    func list(target: BibleAnnotationTarget, bookId: String, chapterNumber: Int?, verseStart: Int?, verseEnd: Int?) async throws -> [BibleAnnotationRecord] { throw Boom() }
    func replace(target: BibleAnnotationTarget, bookId: String, chapterNumber: Int?, verseStart: Int?, verseEnd: Int?, inserting records: [BibleAnnotationRecord]) async throws { throw Boom() }
    func hasAnnotation(target: BibleAnnotationTarget, bookId: String, chapterNumber: Int?, verseStart: Int?, verseEnd: Int?) async throws -> Bool { throw Boom() }
    func hasVerseAnnotations(bookId: String, chapterNumber: Int) async throws -> Bool { throw Boom() }
    func deleteOne(id: String) async throws { throw Boom() }
    func deleteAll() async throws { throw Boom() }
}
