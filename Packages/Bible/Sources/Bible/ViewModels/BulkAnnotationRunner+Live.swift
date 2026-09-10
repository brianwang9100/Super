import Core
import Foundation
import os

private let bulkRunnerLog = Logger(subsystem: "com.brianwang.Super", category: "bible-bulk-runner")

/// Runs units serially by ordinal and persists transitions. Retryable failures exhaust
/// per-unit attempts; auth/quota failures or consecutive unit failures halt the run.
/// Failed units remain manually retryable.
/// Book prologues and notable-verse units participate in completion and persistence
/// but have no separate rows in the live chapter progress grid.
@MainActor
public final class BulkAnnotationRunner: BulkAnnotationRunning {
    public private(set) var snapshot: BulkRunSnapshot?
    public var onSnapshotChange: (@MainActor @Sendable () -> Void)?

    private let ledger: any BulkAnnotationLedger
    private let generator: any BibleAnnotateGenerating
    // Share the generator's database so preserve checks see prior writes.
    private let annotationRepository: any BibleAnnotationRepository
    private let catalog: BibleBookCatalog
    private let translation: BibleTranslation
    private let textLoader: any BibleTextLoader
    private let clock: any Clock
    private let idGenerator: any IDGenerator
    private let currentModelID: @Sendable () async -> String
    private let maxAttemptsPerUnit: Int
    private let consecutiveFailureLimit: Int
    private let completedRunRetention: TimeInterval

    // In-memory mirrors permit synchronous snapshots; the ledger remains authoritative.
    private var runRecord: BulkAnnotationRunRecord?
    private var units: [BulkAnnotationRunUnitRecord] = []
    private var consecutiveFailures = 0

    // Cancel before createRun completes must not persist a phantom cancelled run.
    private var runPersisted = false

    // Retain until actual exit so tests can drain even a cooperatively cancelled call.
    private var driver: Task<Void, Never>?

    // Claim synchronously before async setup. Clear at actual loop exit to prevent
    // overlapping generation when resume/retry arrives during an in-flight unit.
    private var isDriving = false

    // Stop before the next unit while leaving the run active. Resume clears this
    // even if the current loop has not yet exited, avoiding a stranded run.
    private var backgroundStopRequested = false

    // Expiration requeues immediately; discard the abandoned call's eventual result without writes.
    private var expirationAbandoned = false

    // Serialize ledger writes in issue order; draining the tail makes synchronous mutations durable.
    private var lastWrite: Task<Void, Never>?

    public init(
        ledger: any BulkAnnotationLedger,
        generator: any BibleAnnotateGenerating,
        annotationRepository: any BibleAnnotationRepository,
        catalog: BibleBookCatalog = .standard,
        translation: BibleTranslation = .web,
        textLoader: any BibleTextLoader = DatabaseBibleTextLoader(),
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator(),
        currentModelID: @escaping @Sendable () async -> String = { "" },
        maxAttemptsPerUnit: Int = 3,
        consecutiveFailureLimit: Int = 5,
        completedRunRetention: TimeInterval = 24 * 60 * 60
    ) {
        self.ledger = ledger
        self.generator = generator
        self.annotationRepository = annotationRepository
        self.catalog = catalog
        self.translation = translation
        self.textLoader = textLoader
        self.clock = clock
        self.idGenerator = idGenerator
        self.currentModelID = currentModelID
        self.maxAttemptsPerUnit = max(1, maxAttemptsPerUnit)
        self.consecutiveFailureLimit = max(1, consecutiveFailureLimit)
        self.completedRunRetention = completedRunRetention
    }

    // MARK: - BulkAnnotationRunning

    public func start(_ plan: BulkRunPlan) {
        // runRecord alone misses async kickoff/adoption. isDriving reserves that window
        // so simultaneous Generate/Retry cannot claim two runs.
        guard runRecord == nil, !isDriving, !plan.isEmpty else { return }
        let now = clock.now()
        let runID = idGenerator.nextID()

        var newUnits: [BulkAnnotationRunUnitRecord] = []
        var ordinal = 0
        for book in plan.books {
            if book.includesBookLevel {
                newUnits.append(
                    BulkAnnotationRunUnitRecord(
                        id: idGenerator.nextID(),
                        runId: runID,
                        ordinal: ordinal,
                        kind: .bookPrologue,
                        bookId: book.bookID,
                        bookName: book.name,
                        chapterNumber: nil,
                        state: .queued,
                        updatedAt: now
                    )
                )
                ordinal += 1
            }
            for chapter in book.chapters {
                newUnits.append(
                    BulkAnnotationRunUnitRecord(
                        id: idGenerator.nextID(),
                        runId: runID,
                        ordinal: ordinal,
                        kind: .chapter,
                        bookId: book.bookID,
                        bookName: book.name,
                        chapterNumber: chapter,
                        state: .queued,
                        updatedAt: now
                    )
                )
                ordinal += 1
                if plan.includesNotableVerses {
                    newUnits.append(
                        BulkAnnotationRunUnitRecord(
                            id: idGenerator.nextID(),
                            runId: runID,
                            ordinal: ordinal,
                            kind: .chapterVerses,
                            bookId: book.bookID,
                            bookName: book.name,
                            chapterNumber: chapter,
                            state: .queued,
                            updatedAt: now
                        )
                    )
                    ordinal += 1
                }
            }
        }
        guard !newUnits.isEmpty else { return }

        // Resolve model metadata asynchronously; publish queued progress immediately.
        runRecord = BulkAnnotationRunRecord(
            id: runID,
            status: .running,
            modelId: "",
            createdAt: now,
            updatedAt: now,
            overwriteExisting: plan.overwriteExisting
        )
        units = newUnits
        consecutiveFailures = 0
        runPersisted = false
        projectSnapshot()

        isDriving = true
        driver = Task { [weak self] in await self?.persistThenRun() }
    }

    public func togglePause() {
        guard var run = runRecord else { return }
        switch run.status {
        case .running:
            // Pause through run state, preserving the driver so a fast resume can reuse it.
            // If still paused after generation, the unit returns to the queue.
            run.status = .paused
            run.updatedAt = clock.now()
            runRecord = run
            enqueueWrite { [ledger, run] in try await ledger.saveRun(run) }
            projectSnapshot()
        case .paused:
            run.status = .running
            run.updatedAt = clock.now()
            runRecord = run
            enqueueWrite { [ledger, run] in try await ledger.saveRun(run) }
            projectSnapshot()
            startDriver()
        default:
            break
        }
    }

    public func retry(_ ref: ChapterRef) {
        reviveFailedUnits { $0.bookId == ref.bookID && $0.chapterNumber == ref.number }
    }

    public func retryAllFailed() {
        reviveFailedUnits { $0.state == .failed }
    }

    public func cancel() {
        // Clear run state as the authoritative stop signal; Task cancellation is best-effort.
        // Retain driver until its in-flight work exits.
        driver?.cancel()
        if var run = runRecord, runPersisted {
            let now = clock.now()
            run.status = .cancelled
            run.completedAt = now
            run.updatedAt = now
            enqueueWrite { [ledger, run] in try await ledger.saveRun(run) }
        }
        runRecord = nil
        units = []
        runPersisted = false
        snapshot = nil
        notify()
    }

    // MARK: - Finished runs (hub "Recently finished" list)

    /// Claims the engine synchronously before asynchronously loading and reviving a finished run.
    public func resume(runID: String) {
        guard runRecord == nil, !isDriving else { return }
        isDriving = true
        driver = Task { [weak self] in await self?.adoptFinished(runID: runID) }
    }

    public func dismissFinishedRun(id: String) {
        guard runRecord?.id != id else { return }
        enqueueWrite { [ledger] in try await ledger.deleteRun(id: id) }
    }

    // Clear the adopted isDriving claim on every early return; runLoop owns it after handoff.
    private func adoptFinished(runID: String) async {
        guard runRecord == nil else { isDriving = false; return }
        // Settle pending terminal writes before reloading this run.
        await lastWrite?.value
        guard runRecord == nil else { isDriving = false; return }
        guard let run = try? await ledger.run(id: runID), run.completedAt != nil else {
            isDriving = false
            return
        }
        guard runRecord == nil else { isDriving = false; return }
        var loaded = (try? await ledger.units(runId: runID)) ?? []
        guard runRecord == nil else { isDriving = false; return }

        let now = clock.now()
        var hasWork = false
        for index in loaded.indices {
            switch loaded[index].state {
            case .failed, .generating:
                loaded[index].state = .queued
                loaded[index].attemptCount = 0
                loaded[index].errorMessage = nil
                loaded[index].updatedAt = now
                hasWork = true
            case .queued:
                hasWork = true  // a fatal halt left later units unattempted.
            case .done, .skipped:
                break  // terminal — a re-adopt leaves a skipped unit skipped.
            }
        }
        guard hasWork else { isDriving = false; return }

        var revived = run
        revived.status = .running
        revived.haltReason = nil
        revived.completedAt = nil
        revived.updatedAt = now

        // Persist revival before adopting it in memory; direct writes settle before the loop starts.
        await performLogged("saveRun(revived)") { try await ledger.saveRun(revived) }
        for unit in loaded where unit.state == .queued {
            await performLogged("saveUnit(revived)") { try await ledger.saveUnit(unit) }
        }
        guard runRecord == nil else { isDriving = false; return }
        runRecord = revived
        units = loaded
        consecutiveFailures = 0
        runPersisted = true
        projectSnapshot()
        await runLoop()  // clears `isDriving` via its `defer`
    }

    // MARK: - Background execution

    /// Restores/resumes available work, then awaits the driver and ledger-write tail.
    public func runInBackground() async {
        await restore()        // cold relaunch: load + resume an active run; no-op when one's already in memory.
        resumeActiveRun()      // suspended warm: restart a loop a prior expiration stopped; no-op when one's live.
        await driver?.value
        await lastWrite?.value
    }

    /// Requeues an in-flight unit immediately and requests a stop before the next unit.
    /// iOS expiration cannot wait for LLM generation; its eventual outcome is discarded.
    /// The run stays running for later resume. Call flushPendingWrites before completing
    /// the background task to persist this synchronous in-memory transition.
    public func requestExpirationStop() {
        backgroundStopRequested = true
        guard let index = units.firstIndex(where: { $0.state == .generating }) else { return }
        units[index].state = .queued
        units[index].updatedAt = clock.now()
        saveUnit(at: index)
        expirationAbandoned = true
        projectSnapshot()
    }

    /// Persists every issued write, including expiration requeue, before task completion.
    public func flushPendingWrites() async {
        await lastWrite?.value
    }

    /// Clears pending background stop and starts a driver only when none is live;
    /// an existing loop can continue without waiting for another lifecycle event.
    public func resumeActiveRun() {
        guard let run = runRecord, run.status == .running else { return }
        backgroundStopRequested = false
        startDriver()  // single-flight: no-ops if a loop is already live.
    }

    // MARK: - Resume on launch

    /// Resets crash-orphaned generating units to queued. Running resumes; paused stays parked.
    public func restore() async {
        // Sweep finished history on every launch, even without an active run.
        let cutoff = clock.now().addingTimeInterval(-completedRunRetention)
        await performLogged("deleteRunsCompleted") { try await ledger.deleteRunsCompleted(before: cutoff) }

        // User actions claim isDriving before assigning runRecord. Restore must yield to
        // that claim or it can adopt a run whose driver cannot start.
        guard runRecord == nil, !isDriving else { return }  // resume once; never clobber a live/claimed run.
        guard let run = try? await ledger.activeRun() else { return }
        guard runRecord == nil, !isDriving else { return }  // a run may have started/been claimed during the await.
        var loaded = (try? await ledger.units(runId: run.id)) ?? []
        let now = clock.now()
        for index in loaded.indices where loaded[index].state == .generating {
            loaded[index].state = .queued
            loaded[index].updatedAt = now
            // Await restore writes before starting the loop, outside the normal write tail.
            await performLogged("saveUnit(restore)") { try await ledger.saveUnit(loaded[index]) }
        }
        // No suspension between this final guard and claim, so adoption is atomic on MainActor.
        guard runRecord == nil, !isDriving else { return }
        runRecord = run
        units = loaded
        consecutiveFailures = 0
        runPersisted = true  // the run already exists in the ledger.
        projectSnapshot()
        if run.status == .running {
            startDriver()
        }
    }

    // MARK: - Work loop

    // Clear isDriving on every early exit, then hand ownership to runLoop. Do not use
    // a function-wide defer: after await runLoop returns, it could erase a newer resume
    // claim made during the resumption gap and admit a second loop.
    private func persistThenRun() async {
        guard var run = runRecord else { isDriving = false; return }
        run.modelId = await currentModelID()
        // Cancellation during model lookup must not resurrect the cleared run.
        guard runRecord?.id == run.id else { isDriving = false; return }
        runRecord = run
        do {
            try await ledger.createRun(run, units: units)
        } catch {
            bulkRunnerLog.error("bulk-annotation createRun failed: \(error.localizedDescription, privacy: .public)")
            runRecord = nil
            units = []
            snapshot = nil
            isDriving = false
            notify()
            return
        }
        // Cancellation during createRun could not delete an unpersisted row; undo it now.
        guard runRecord?.id == run.id else {
            await performLogged("deleteRun(undo)") { try await ledger.deleteRun(id: run.id) }
            isDriving = false
            return
        }
        runPersisted = true
        await runLoop()  // clears `isDriving` via its `defer`
    }

    private func startDriver() {
        guard !isDriving else { return }
        isDriving = true
        driver = Task { [weak self] in await self?.runLoop() }
    }

    private func runLoop() async {
        backgroundStopRequested = false
        expirationAbandoned = false
        defer { isDriving = false }
        while !Task.isCancelled {
            guard runRecord?.status == .running else { return }
            guard let index = units.firstIndex(where: { $0.state == .queued }) else {
                finalizeCompleted()
                return
            }
            // Finalize drained work before honoring background stop; only new units must wait.
            if backgroundStopRequested { return }

            if runRecord?.overwriteExisting == false {
                let occupied: Bool
                do {
                    occupied = try await slotOccupied(for: units[index])
                } catch {
                    // An uncertain preserve check must neither overwrite nor skip silently. Fail the
                    // unit so manual retry and the run-level breaker handle database failures.
                    if runRecord == nil { return }
                    if runRecord?.status != .running { return }
                    failUnit(at: index, message: "Couldn't check existing annotations: \(error.localizedDescription)")
                    consecutiveFailures += 1
                    projectSnapshot()
                    if consecutiveFailures >= consecutiveFailureLimit {
                        haltRun(reason: .consecutiveFailures)
                        return
                    }
                    continue
                }
                // Recheck after the read; paused work must remain queued for resume.
                if runRecord == nil { return }
                if runRecord?.status != .running { return }
                if occupied {
                    units[index].state = .skipped
                    units[index].updatedAt = clock.now()
                    saveUnit(at: index)
                    consecutiveFailures = 0  // a skip is not a failure — don't trip the breaker.
                    projectSnapshot()
                    continue
                }
            }

            units[index].state = .generating
            units[index].updatedAt = clock.now()
            saveUnit(at: index)
            projectSnapshot()

            let reference = makeReference(for: units[index])
            let outcome = await generator.generate(reference: reference)

            // Run state distinguishes cancellation from pause after an in-flight request.
            if runRecord == nil { return }  // cancelled: run torn down, touch nothing.
            if expirationAbandoned {
                // Expiration already requeued this unit. Discard the outcome and re-evaluate so
                // a foreground resume during the await can continue without waiting for a new event.
                expirationAbandoned = false
                continue
            }
            if runRecord?.status != .running {
                // Paused generation is discarded and requeued for resume.
                units[index].state = .queued
                units[index].updatedAt = clock.now()
                saveUnit(at: index)
                projectSnapshot()
                return
            }

            switch outcome {
            case .success(let annotationCount):
                units[index].state = .done
                units[index].producedCount = annotationCount
                units[index].attemptCount += 1
                units[index].updatedAt = clock.now()
                saveUnit(at: index)
                consecutiveFailures = 0
                projectSnapshot()

            case .failure(let message, .fatalAuth):
                failUnit(at: index, message: message)
                haltRun(reason: .auth)
                return

            case .failure(let message, .fatalQuota):
                failUnit(at: index, message: message)
                haltRun(reason: .quota)
                return

            case .failure(let message, .retryable):
                units[index].attemptCount += 1
                units[index].errorMessage = message
                consecutiveFailures += 1
                units[index].state =
                    units[index].attemptCount >= maxAttemptsPerUnit ? .failed : .queued
                units[index].updatedAt = clock.now()
                saveUnit(at: index)
                projectSnapshot()
                if consecutiveFailures >= consecutiveFailureLimit {
                    haltRun(reason: .consecutiveFailures)
                    return
                }
            }
        }
    }

    // MARK: - State transitions

    private func failUnit(at index: Int, message: String) {
        units[index].state = .failed
        units[index].errorMessage = message
        units[index].attemptCount += 1
        units[index].updatedAt = clock.now()
        saveUnit(at: index)
    }

    private func haltRun(reason: BulkRunHaltReason) {
        guard var run = runRecord else { return }
        let now = clock.now()
        run.status = .failed
        run.haltReason = reason
        run.completedAt = now
        run.updatedAt = now
        enqueueWrite { [ledger, run] in try await ledger.saveRun(run) }
        finishActiveRun()
    }

    private func finalizeCompleted() {
        guard var run = runRecord else { return }
        let now = clock.now()
        run.status = .completed
        run.completedAt = now
        run.updatedAt = now
        enqueueWrite { [ledger, run] in try await ledger.saveRun(run) }
        finishActiveRun()
    }

    // Terminal persistence is already queued; release only the active in-memory slot.
    private func finishActiveRun() {
        runRecord = nil
        units = []
        consecutiveFailures = 0
        runPersisted = false
        projectSnapshot()  // runRecord == nil → snapshot becomes nil
    }

    private func reviveFailedUnits(_ predicate: (BulkAnnotationRunUnitRecord) -> Bool) {
        guard runRecord != nil else { return }
        let now = clock.now()
        var revivedAny = false
        for index in units.indices where units[index].state == .failed && predicate(units[index]) {
            units[index].state = .queued
            units[index].attemptCount = 0
            units[index].errorMessage = nil
            units[index].updatedAt = now
            saveUnit(at: index)
            revivedAny = true
        }
        guard revivedAny else { return }

        consecutiveFailures = 0
        if var run = runRecord, run.status != .running {
            run.status = .running
            run.haltReason = nil
            run.completedAt = nil
            run.updatedAt = now
            runRecord = run
            enqueueWrite { [ledger, run] in try await ledger.saveRun(run) }
        }
        projectSnapshot()
        startDriver()
    }

    // MARK: - Persistence

    // Chain writes in issue order. Log failures to diagnose divergence from the in-memory mirror.
    private func enqueueWrite(_ work: @escaping @Sendable () async throws -> Void) {
        lastWrite = Task { [prev = lastWrite] in
            await prev?.value
            do {
                try await work()
            } catch {
                bulkRunnerLog.error("bulk-annotation ledger write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func performLogged(_ label: String, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            bulkRunnerLog.error("bulk-annotation \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveUnit(at index: Int) {
        let unit = units[index]
        enqueueWrite { [ledger] in try await ledger.saveUnit(unit) }
    }

    // MARK: - Projection

    private func projectSnapshot() {
        guard let run = runRecord else {
            snapshot = nil
            notify()
            return
        }
        var books: [BulkBookProgress] = []
        var indexByBook: [String: Int] = [:]
        for unit in units {
            guard unit.kind == .chapter, let number = unit.chapterNumber else { continue }
            let chapter = BulkChapterProgress(
                number: number,
                state: unit.state,
                producedCount: unit.producedCount
            )
            if let bookIndex = indexByBook[unit.bookId] {
                books[bookIndex].chapters.append(chapter)
            } else {
                indexByBook[unit.bookId] = books.count
                books.append(
                    BulkBookProgress(bookID: unit.bookId, name: unit.bookName, chapters: [chapter])
                )
            }
        }
        snapshot = BulkRunSnapshot(books: books, isRunning: run.status == .running)
        notify()
    }

    private func notify() { onSnapshotChange?() }

    // MARK: - Target slot

    // Chapter/book slots are deterministic. Notable ranges are chosen during generation,
    // so any existing verse annotation satisfies their preserve check.
    private func slotOccupied(for unit: BulkAnnotationRunUnitRecord) async throws -> Bool {
        switch unit.kind {
        case .bookPrologue:
            try await annotationRepository.hasAnnotation(
                target: .book, bookId: unit.bookId,
                chapterNumber: nil, verseStart: nil, verseEnd: nil
            )
        case .chapter:
            try await annotationRepository.hasAnnotation(
                target: .chapter, bookId: unit.bookId,
                chapterNumber: unit.chapterNumber, verseStart: nil, verseEnd: nil
            )
        case .chapterVerses:
            try await annotationRepository.hasVerseAnnotations(
                bookId: unit.bookId, chapterNumber: unit.chapterNumber ?? 0
            )
        }
    }

    // MARK: - Reference

    // Keep reference encoding aligned with single-target dispatch. Chapter and notable-verse
    // units carry numbered text; book prologues omit it to bound prompt size.
    private func makeReference(for unit: BulkAnnotationRunUnitRecord) -> RecordReference {
        let kind: String
        let sourceID: String
        let label: String
        var snapshot = ""
        switch unit.kind {
        case .bookPrologue:
            kind = "book"
            sourceID = "book:\(unit.bookId)"
            label = unit.bookName
        case .chapter:
            let chapterNumber = unit.chapterNumber ?? 0
            kind = "chapter"
            sourceID = "chapter:\(unit.bookId):\(chapterNumber)"
            label = "\(unit.bookName) \(chapterNumber)"
            snapshot = chapterSnapshot(bookId: unit.bookId, chapterNumber: chapterNumber)
        case .chapterVerses:
            let chapterNumber = unit.chapterNumber ?? 0
            kind = "chapterVerses"
            sourceID = "chapterVerses:\(unit.bookId):\(chapterNumber)"
            label = "\(unit.bookName) \(chapterNumber)"
            snapshot = chapterSnapshot(bookId: unit.bookId, chapterNumber: chapterNumber)
        }
        return RecordReference(
            appletID: BibleApplet.appletID,
            kind: kind,
            sourceID: sourceID,
            displayLabel: label,
            citation: "\(label) (\(translation.rawValue))",
            snapshot: snapshot,
            id: idGenerator.nextID()
        )
    }

    private func chapterSnapshot(bookId: String, chapterNumber: Int) -> String {
        guard let chapter = (try? textLoader.loadChapter(
            bookId: bookId, chapterNumber: chapterNumber, translation: translation
        )) ?? nil else { return "" }
        return BibleVerseTextFormatter.numbered(chapter.coalescedVerses())
    }

    // MARK: - Test seam

    /// Drains the current driver and every issued ledger write without scheduler polling.
    func _waitUntilIdle() async {
        await driver?.value
        await lastWrite?.value
    }
}
