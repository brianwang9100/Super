import Core
import Foundation

/// The LLM-backed bulk-annotation engine — the production `BulkAnnotationRunning`
/// the Settings → Annotations hub drives once a run is kicked off.
///
/// It walks a run's units one at a time in `ordinal` order, asking the injected
/// `BibleAnnotateGenerating` (a `.userBulk`-stamped `BibleAnnotateDispatcher`,
/// supplied at the composition root) to generate each chapter, and records every
/// transition to the durable `BulkAnnotationLedger`. The published `snapshot` is
/// projected from the in-memory unit copy the ledger writes mirror, so the hub
/// and per-book progress read the same vocabulary the fake produced.
///
/// **Three failure tiers** (matching the design):
/// - *Per-unit retry* — a `.retryable` outcome re-queues the same unit until
///   `maxAttemptsPerUnit` is reached, then marks it `.failed`.
/// - *Run-level circuit breaker* — a fatal `.fatalAuth` / `.fatalQuota` outcome
///   halts the whole run immediately (`status .failed`, matching `haltReason`),
///   and `consecutiveFailureLimit` retryable failures in a row trips
///   `.consecutiveFailures`. All three protect the user's wallet by stopping the
///   run rather than burning requests on a persistent error.
/// - *Manual retry* — `retry(_:)` / `retryAllFailed()` revive `.failed` units.
///
/// Book **prologues** are deferred: `BulkChapterProgress` can only carry a
/// chapter number, so `kind == .bookPrologue` units are skipped in the snapshot.
/// The current `BulkRunPlan` only ever yields chapter units, so this is a
/// forward-guard, not a regression.
@MainActor
public final class BulkAnnotationRunner: BulkAnnotationRunning {
    public private(set) var snapshot: BulkRunSnapshot?
    public var onSnapshotChange: (@MainActor @Sendable () -> Void)?

    private let ledger: any BulkAnnotationLedger
    private let generator: any BibleAnnotateGenerating
    private let catalog: BibleBookCatalog
    private let translation: BibleTranslation
    private let clock: any Clock
    private let idGenerator: any IDGenerator
    private let currentModelID: @Sendable () async -> String
    private let maxAttemptsPerUnit: Int
    private let consecutiveFailureLimit: Int

    /// Authoritative state lives in the ledger; these mirror it in memory so the
    /// snapshot can be projected synchronously without a round-trip.
    private var runRecord: BulkAnnotationRunRecord?
    private var units: [BulkAnnotationRunUnitRecord] = []
    private var consecutiveFailures = 0

    /// The in-flight work loop, retained until it actually exits so
    /// `waitUntilIdle()` can await it. Pause/cancel signal the loop through run
    /// state (below) rather than Task cancellation, so the loop is never torn
    /// down mid-unit and a superseded second loop can't appear.
    private var driver: Task<Void, Never>?

    /// `true` while a work loop is live (from the moment one is kicked off until
    /// it returns). The single source of truth for "is the engine already
    /// draining?": `startDriver()` no-ops when it's set, so resume/retry while a
    /// unit is mid-flight let the existing loop pick up the new work instead of
    /// spawning a second concurrent loop (which would double-generate and corrupt
    /// the breaker counter). Cleared in `runLoop`'s `defer`, synchronously at
    /// every exit, so it's reliably `false` the instant no loop is running.
    private var isDriving = false

    /// Serialized tail of all ledger writes. Each write chains on the previous so
    /// upserts apply in issue order (a pause's `saveRun` before a later resume's),
    /// and `waitUntilIdle()` can await the durable state having caught up — even
    /// for writes kicked off by the synchronous `BulkAnnotationRunning` mutators.
    private var lastWrite: Task<Void, Never>?

    public init(
        ledger: any BulkAnnotationLedger,
        generator: any BibleAnnotateGenerating,
        catalog: BibleBookCatalog = .standard,
        translation: BibleTranslation = .web,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator(),
        currentModelID: @escaping @Sendable () async -> String = { "" },
        maxAttemptsPerUnit: Int = 3,
        consecutiveFailureLimit: Int = 5
    ) {
        self.ledger = ledger
        self.generator = generator
        self.catalog = catalog
        self.translation = translation
        self.clock = clock
        self.idGenerator = idGenerator
        self.currentModelID = currentModelID
        self.maxAttemptsPerUnit = max(1, maxAttemptsPerUnit)
        self.consecutiveFailureLimit = max(1, consecutiveFailureLimit)
    }

    // MARK: - BulkAnnotationRunning

    public func start(_ plan: BulkRunPlan) {
        // One active run at a time. The hub already gates this on `!isRunning`;
        // guarding here too keeps the engine from leaking a loop or creating a
        // second ledger row if `start` is ever called while a run exists.
        guard runRecord == nil, !plan.isEmpty else { return }
        let now = clock.now()
        let runID = idGenerator.nextID()

        var newUnits: [BulkAnnotationRunUnitRecord] = []
        var ordinal = 0
        for book in plan.books {
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
            }
        }
        guard !newUnits.isEmpty else { return }

        // `modelId` is filled in by the async driver (it needs the actor-isolated
        // registry); the snapshot doesn't depend on it, so the placeholder never
        // surfaces. Project immediately so the hub shows queued rows at once.
        runRecord = BulkAnnotationRunRecord(
            id: runID,
            status: .running,
            modelId: "",
            createdAt: now,
            updatedAt: now
        )
        units = newUnits
        consecutiveFailures = 0
        projectSnapshot()

        isDriving = true
        driver = Task { [weak self] in await self?.persistThenRun() }
    }

    public func togglePause() {
        guard var run = runRecord else { return }
        switch run.status {
        case .running:
            // Signal the loop to stop after the current unit via run state — the
            // loop checks `status` before each unit and after each generate, and
            // returns the in-flight unit to the queue. We don't cancel the driver
            // (cancellation can't interrupt the in-flight LLM call anyway, and
            // leaving the loop intact lets a fast resume continue on it).
            run.status = .paused
            run.updatedAt = clock.now()
            runRecord = run
            enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
            projectSnapshot()
        case .paused:
            run.status = .running
            run.updatedAt = clock.now()
            runRecord = run
            enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
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
        // Tearing down the run state stops the loop (it bails on `runRecord ==
        // nil` after the in-flight generate returns); the `cancel()` is a
        // best-effort cooperative abort of that call. We keep `driver` so
        // `waitUntilIdle()` can await the loop's actual exit.
        driver?.cancel()
        if var run = runRecord {
            let now = clock.now()
            run.status = .cancelled
            run.completedAt = now
            run.updatedAt = now
            enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
        }
        runRecord = nil
        units = []
        snapshot = nil
        notify()
    }

    // MARK: - Resume on launch

    /// Reload the single active run (if any) and resume it. Any unit left
    /// `.generating` by a crash mid-call is reset to `.queued` so it re-runs.
    /// A `.paused` run is restored parked; a `.running` one resumes its loop.
    public func restore() async {
        guard runRecord == nil else { return }  // resume once; never clobber a live run.
        guard let run = try? await ledger.activeRun() else { return }
        var loaded = (try? await ledger.units(runId: run.id)) ?? []
        let now = clock.now()
        for index in loaded.indices where loaded[index].state == .generating {
            loaded[index].state = .queued
            loaded[index].updatedAt = now
            // Awaited directly (not via the `enqueueWrite` chain) — these all
            // settle before `startDriver()`, and nothing else mutates state
            // during restore, so ordering holds without the serialized tail.
            try? await ledger.saveUnit(loaded[index])
        }
        runRecord = run
        units = loaded
        consecutiveFailures = 0
        projectSnapshot()
        if run.status == .running {
            startDriver()
        }
    }

    // MARK: - Work loop

    private func persistThenRun() async {
        guard var run = runRecord else { isDriving = false; return }
        run.modelId = await currentModelID()
        runRecord = run
        do {
            try await ledger.createRun(run, units: units)
        } catch {
            // Couldn't persist the run — treat it as never-started so the hub
            // returns to idle rather than showing a phantom job.
            runRecord = nil
            units = []
            snapshot = nil
            isDriving = false
            notify()
            return
        }
        await runLoop()  // clears `isDriving` via its `defer`
    }

    /// Kick a work loop unless one is already live. Single-flight: a resume or
    /// retry that arrives while a unit is mid-flight no-ops here and lets the
    /// running loop pick up the freshly-queued work, rather than starting a
    /// second concurrent loop.
    private func startDriver() {
        guard !isDriving else { return }
        isDriving = true
        driver = Task { [weak self] in await self?.runLoop() }
    }

    private func runLoop() async {
        // Cleared synchronously at every exit, so `isDriving` is reliably `false`
        // the instant the loop stops — which is what makes `startDriver()`'s
        // single-flight guard correct.
        defer { isDriving = false }
        while !Task.isCancelled {
            guard runRecord?.status == .running else { return }
            guard let index = units.firstIndex(where: { $0.state == .queued }) else {
                finalizeCompleted()
                return
            }

            units[index].state = .generating
            units[index].updatedAt = clock.now()
            saveUnit(at: index)
            projectSnapshot()

            let reference = makeReference(for: units[index])
            let outcome = await generator.generate(reference: reference)

            // Cancel / pause may have landed while the request was in flight
            // (both cancel the driver Task, so `Task.isCancelled` can't tell them
            // apart — distinguish on the run state cancel/pause leave behind).
            if runRecord == nil { return }  // cancelled: run torn down, touch nothing.
            if runRecord?.status != .running {
                // Paused mid-flight: return the unit to the queue (discarding this
                // outcome) so resume re-generates it instead of skipping it.
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
        runRecord = run
        enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
        projectSnapshot()
    }

    private func finalizeCompleted() {
        guard var run = runRecord else { return }
        let now = clock.now()
        run.status = .completed
        run.completedAt = now
        run.updatedAt = now
        runRecord = run
        enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
        projectSnapshot()
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
            enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
        }
        projectSnapshot()
        startDriver()
    }

    // MARK: - Persistence

    /// Append a write to the serialized chain so writes apply in issue order and
    /// `waitUntilIdle()` can await them.
    private func enqueueWrite(_ work: @escaping @Sendable () async -> Void) {
        lastWrite = Task { [prev = lastWrite] in
            await prev?.value
            await work()
        }
    }

    private func saveUnit(at index: Int) {
        let unit = units[index]
        enqueueWrite { [ledger] in try? await ledger.saveUnit(unit) }
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

    // MARK: - Reference

    /// Build the per-chapter `RecordReference` the dispatcher annotates — mirrors
    /// `BibleScreenViewModel.makeAnnotateRequestReference`: `snapshot: ""` because
    /// the model knows the passage from the citation (same as the spark-button
    /// per-target path).
    private func makeReference(for unit: BulkAnnotationRunUnitRecord) -> RecordReference {
        let chapterNumber = unit.chapterNumber ?? 0
        let label = "\(unit.bookName) \(chapterNumber)"
        return RecordReference(
            appletID: BibleApplet.appletID,
            kind: "chapter",
            sourceID: "chapter:\(unit.bookId):\(chapterNumber)",
            displayLabel: label,
            citation: "\(label) (\(translation.rawValue))",
            snapshot: "",
            id: idGenerator.nextID()
        )
    }

    // MARK: - Test seam

    /// Await the current work loop and all issued ledger writes to settle
    /// (completed, halted, paused, or cancelled). Lets tests drive the engine
    /// deterministically with no sleeps.
    func waitUntilIdle() async {
        await driver?.value
        await lastWrite?.value
    }
}
