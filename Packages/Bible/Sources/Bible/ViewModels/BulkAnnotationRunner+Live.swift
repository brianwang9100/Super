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
/// A whole-book selection enqueues one **book-level** (`.bookPrologue`) unit
/// ahead of that book's chapters; the engine generates it like any other unit
/// (a `kind == "book"` reference). `BulkChapterProgress` can only carry a chapter
/// number, so book-level units are intentionally absent from the live progress
/// grid — they still generate, persist, and count toward run completion, just
/// without a dedicated progress row.
@MainActor
public final class BulkAnnotationRunner: BulkAnnotationRunning {
    public private(set) var snapshot: BulkRunSnapshot?
    public var onSnapshotChange: (@MainActor @Sendable () -> Void)?

    private let ledger: any BulkAnnotationLedger
    private let generator: any BibleAnnotateGenerating
    /// Reads whether a unit's target slot is already annotated, for preserve
    /// mode's skip-before-generate check. The same `bible.sqlite` the generator
    /// writes through, so a slot a prior unit in this run just filled reads as
    /// occupied for a later same-slot unit.
    private let annotationRepository: any BibleAnnotationRepository
    private let catalog: BibleBookCatalog
    private let translation: BibleTranslation
    private let textLoader: any BibleTextLoader
    private let clock: any Clock
    private let idGenerator: any IDGenerator
    private let currentModelID: @Sendable () async -> String
    private let maxAttemptsPerUnit: Int
    private let consecutiveFailureLimit: Int
    /// How long a terminal run lingers in the "Recently finished" list before the
    /// launch sweep removes it (default 24 h). Injectable so tests can sweep
    /// without waiting.
    private let completedRunRetention: TimeInterval

    /// Authoritative state lives in the ledger; these mirror it in memory so the
    /// snapshot can be projected synchronously without a round-trip.
    private var runRecord: BulkAnnotationRunRecord?
    private var units: [BulkAnnotationRunUnitRecord] = []
    private var consecutiveFailures = 0

    /// `true` once the run row has actually been written to the ledger
    /// (`createRun` returned). Guards `cancel()` from persisting a `.cancelled`
    /// row for a run that was torn down before it ever reached the ledger —
    /// otherwise a cancel during `start`'s async setup leaves a phantom row in
    /// `completedRuns()`.
    private var runPersisted = false

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

    /// Set when a background task runs out of time (`requestBackgroundStop()`):
    /// the live loop finishes the in-flight unit, saving its result, then stops
    /// before the next one — leaving the run `.running` so a later foreground or
    /// background resume continues it. Cleared at the top of every fresh loop,
    /// and by `resumeActiveRun()` (which cancels a pending stop rather than
    /// letting a just-arrived foreground race the loop into a wedged state).
    private var backgroundStopRequested = false

    /// Serialized tail of all ledger writes. Each write chains on the previous so
    /// upserts apply in issue order (a pause's `saveRun` before a later resume's),
    /// and `waitUntilIdle()` can await the durable state having caught up — even
    /// for writes kicked off by the synchronous `BulkAnnotationRunning` mutators.
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
        // One active run at a time. The hub already gates this on `!isRunning`;
        // guarding here too keeps the engine from leaking a loop or creating a
        // second ledger row if `start` is ever called while a run exists. The
        // `!isDriving` clause closes the kickoff window: `start`/`resume` both
        // claim the engine by setting `isDriving = true` synchronously before
        // their async setup, so a near-simultaneous Generate-then-Retry (or
        // double-Generate) can't both pass while `runRecord` is still nil.
        guard runRecord == nil, !isDriving, !plan.isEmpty else { return }
        let now = clock.now()
        let runID = idGenerator.nextID()

        var newUnits: [BulkAnnotationRunUnitRecord] = []
        var ordinal = 0
        for book in plan.books {
            // A whole-book selection generates one book-level annotation first
            // (ordinal ahead of its chapters), so it lands before — and the run
            // finalizes together with — the visible chapter rows. `bookPrologue`
            // units carry no `chapterNumber`.
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
        if var run = runRecord, runPersisted {
            let now = clock.now()
            run.status = .cancelled
            run.completedAt = now
            run.updatedAt = now
            enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
        }
        runRecord = nil
        units = []
        runPersisted = false
        snapshot = nil
        notify()
    }

    // MARK: - Finished runs (hub "Recently finished" list)

    /// Re-adopt a finished run as the active job and resume it. Claims the engine
    /// synchronously (`isDriving`) so it can't race a near-simultaneous `start`;
    /// the actual reload + revive happens off the spawned Task.
    public func resume(runID: String) {
        guard runRecord == nil, !isDriving else { return }
        isDriving = true
        driver = Task { [weak self] in await self?.adoptFinished(runID: runID) }
    }

    /// Delete a finished run from the ledger (the list's dismiss control). The
    /// reactive `FinishedRunsRequest` drops the row from the section.
    public func dismissFinishedRun(id: String) {
        // The active run is never in the finished list; guard so a stale id can't
        // tear down a freshly-started run sharing it.
        guard runRecord?.id != id else { return }
        enqueueWrite { [ledger] in try? await ledger.deleteRun(id: id) }
    }

    /// Reload a terminal run, revive its failed (and crash-orphaned `.generating`)
    /// units to `.queued`, flip the run back to `.running`, and resume the loop.
    /// Owns `isDriving` (claimed by `resume`) exactly like `persistThenRun`:
    /// cleared on every early return, handed to `runLoop` on the happy path.
    private func adoptFinished(runID: String) async {
        guard runRecord == nil else { isDriving = false; return }
        // Drain any still-pending terminal write for this run so the reload below
        // reads its settled state rather than a row mid-transition.
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
        // A clean completion has nothing to redo — leave it terminal in the list.
        guard hasWork else { isDriving = false; return }

        var revived = run
        revived.status = .running
        revived.haltReason = nil
        revived.completedAt = nil
        revived.updatedAt = now

        // Persist the revival before taking ownership (awaited directly, as in
        // `restore()` — nothing else mutates state during adoption). The run row
        // dropping its `completedAt` removes it from the finished list.
        try? await ledger.saveRun(revived)
        for unit in loaded where unit.state == .queued {
            try? await ledger.saveUnit(unit)
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

    /// Drive the active run for a background task: pick up an in-memory run whose
    /// loop a prior expiration stopped (or, after a cold relaunch, the one
    /// `restore()` loads from the ledger), then await the loop to its next
    /// stopping point — the run draining, halting, or a fresh
    /// `requestBackgroundStop()`. Safe to call with no active run (returns at
    /// once).
    public func runInBackground() async {
        await restore()        // cold relaunch: load + resume an active run; no-op when one's already in memory.
        resumeActiveRun()      // suspended warm: restart a loop a prior expiration stopped; no-op when one's live.
        await driver?.value
        // Drain the serialized write tail too, so the ledger reflects the run's
        // settled state (e.g. a just-finalized `.completed`) before the caller
        // decides whether to reschedule.
        await lastWrite?.value
    }

    /// Ask the live work loop to stop after the current unit because a background
    /// task ran out of time. The run stays active (its status is untouched), so
    /// `resumeActiveRun()` — on the next foreground or background task — continues
    /// it. No-op beyond setting the flag when no loop is running.
    public func requestBackgroundStop() {
        backgroundStopRequested = true
    }

    /// Restart the work loop for an active `.running` run that has no live loop —
    /// the app foregrounding after a background-stop, or a fresh background task
    /// picking the run back up. Clearing `backgroundStopRequested` first cancels a
    /// just-fired stop so a loop still winding down keeps going (rather than
    /// exiting and leaving the run with no driver). No-op when there's no run, it
    /// isn't running, or a loop is already draining.
    public func resumeActiveRun() {
        guard let run = runRecord, run.status == .running else { return }
        backgroundStopRequested = false
        startDriver()  // single-flight: no-ops if a loop is already live.
    }

    // MARK: - Resume on launch

    /// Reload the single active run (if any) and resume it. Any unit left
    /// `.generating` by a crash mid-call is reset to `.queued` so it re-runs.
    /// A `.paused` run is restored parked; a `.running` one resumes its loop.
    public func restore() async {
        // Launch-time sweep of stale finished runs (older than the retention
        // window) — runs unconditionally, before the active-run guards, so it
        // happens whether or not there's a run to resume.
        let cutoff = clock.now().addingTimeInterval(-completedRunRetention)
        try? await ledger.deleteRunsCompleted(before: cutoff)

        // `restore` runs as a fire-and-forget Task at launch, concurrently with a
        // live hub. A user-initiated `start`/`resume` claims the engine by setting
        // `isDriving = true` synchronously before its async setup, *before* it
        // assigns `runRecord`. So guarding on `runRecord == nil` alone isn't
        // enough: restore could pass that guard while a `resume`'s `adoptFinished`
        // is mid-setup, then adopt the orphaned active run and call `startDriver()`
        // — which no-ops against the resume's claim, leaving a run with no loop
        // (wedged until relaunch). Bailing on `!isDriving` cedes to the in-flight
        // user action, which will drive its own (or, if it bails, a later launch
        // restores cleanly).
        guard runRecord == nil, !isDriving else { return }  // resume once; never clobber a live/claimed run.
        guard let run = try? await ledger.activeRun() else { return }
        guard runRecord == nil, !isDriving else { return }  // a run may have started/been claimed during the await.
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
        // Final re-check before taking ownership: from here to `startDriver()`
        // (which claims `isDriving`) there is no suspension, so the claim is
        // atomic on the MainActor and a concurrent `start`/`resume` either
        // already tripped the guard above or will trip its own `runRecord == nil`.
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

    // Ownership note: `isDriving` was set `true` synchronously by `start()` before
    // this Task was spawned; this function owns clearing it. Every early return
    // here must clear it explicitly; the happy path hands ownership to `runLoop`,
    // whose `defer` clears it. It is deliberately NOT a `defer` at this function's
    // top: that would fire after `await runLoop()` returns, and a resume landing
    // in the await-resumption gap (its `startDriver` having set `isDriving = true`)
    // would then be clobbered back to `false`, admitting a second loop. Any new
    // early-return branch added before `runLoop` must clear `isDriving`.
    private func persistThenRun() async {
        guard var run = runRecord else { isDriving = false; return }
        run.modelId = await currentModelID()
        // `cancel()` can land during the await above. Don't resurrect a torn-down
        // run — that would persist a job the user already cancelled.
        guard runRecord?.id == run.id else { isDriving = false; return }
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
        // Or `cancel()` landed during `createRun` (it wrote nothing, since
        // `runPersisted` was still false) — undo the just-persisted run row.
        guard runRecord?.id == run.id else {
            try? await ledger.deleteRun(id: run.id)
            isDriving = false
            return
        }
        runPersisted = true
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
        // A fresh loop never starts pre-stopped: clear any background-stop left by
        // a prior loop that has since exited.
        backgroundStopRequested = false
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
            // A background task that ran out of time asked us to wind down: stop
            // before starting the next unit, leaving the run active for a later
            // resume. Checked only once real work remains (an already-drained run
            // still finalizes above), and after the in-flight unit's result was
            // saved on the prior iteration — so no generation is wasted.
            if backgroundStopRequested { return }

            // Preserve mode (the default): skip a unit whose target slot is
            // already annotated, with no LLM call. The slot is deterministic
            // from `unit.kind` (a `.chapter` unit writes a `.chapter`-target
            // card; a `.bookPrologue` writes a `.book`-target one), so the skip
            // is decided here without knowing the model's output. `overwriteExisting`
            // bypasses the check and regenerates as before.
            if runRecord?.overwriteExisting == false {
                let slot = targetSlot(for: units[index])
                let occupied = (try? await annotationRepository.hasAnnotation(
                    target: slot.target,
                    bookId: units[index].bookId,
                    chapterNumber: slot.chapterNumber,
                    verseStart: nil,
                    verseEnd: nil
                )) ?? false
                // Cancel / pause may have landed during the read; bail the same
                // way the post-generate block does (leave the unit `.queued` on
                // pause so resume re-evaluates it).
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

            // Cancel / pause may have landed while the request was in flight.
            // Distinguish them by the state each leaves behind, not
            // `Task.isCancelled`: `cancel()` clears `runRecord` (and also marks
            // the Task cancelled, but that signal alone can't tell cancel from
            // pause); `togglePause()` only sets the status to `.paused`.
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
        enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
        finishActiveRun()
    }

    private func finalizeCompleted() {
        guard var run = runRecord else { return }
        let now = clock.now()
        run.status = .completed
        run.completedAt = now
        run.updatedAt = now
        enqueueWrite { [ledger, run] in try? await ledger.saveRun(run) }
        finishActiveRun()
    }

    /// Drop a just-finished run from the active slot so the hub returns to idle
    /// (the Generate CTA comes back) and the run surfaces in the "Recently
    /// finished" list instead. The terminal run row is already enqueued by the
    /// caller; clearing the in-memory mirror here projects a `nil` snapshot. The
    /// run lives on in the ledger until dismissed or swept.
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

    // MARK: - Target slot

    /// The annotation target slot a unit writes into — the key preserve mode's
    /// skip check reads against. Mirrors `makeReference`'s `kind` switch: a
    /// `.chapter` unit lands a `.chapter`-target card at `(bookId, chapterNumber)`;
    /// a `.bookPrologue` lands a `.book`-target card at `(bookId)`.
    private func targetSlot(
        for unit: BulkAnnotationRunUnitRecord
    ) -> (target: BibleAnnotationTarget, chapterNumber: Int?) {
        switch unit.kind {
        case .bookPrologue: (.book, nil)
        case .chapter: (.chapter, unit.chapterNumber)
        }
    }

    // MARK: - Reference

    /// Build the per-unit `RecordReference` the dispatcher annotates — mirrors
    /// `BibleScreenViewModel.makeAnnotateRequestReference` (same `kind` /
    /// `sourceID` / `citation` shape per target) so the headless prompt names the
    /// target identically to the single-shot spark-button path.
    ///
    /// A `.chapter` unit carries the chapter's verbatim, verse-numbered text in
    /// `snapshot` so the generator annotates the actual translation rather than
    /// its recollection. A `.bookPrologue` leaves `snapshot: ""` — the whole book
    /// would be an enormous prompt, and book-level cards don't quote verses.
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

    /// The chapter's verbatim, verse-numbered text from the bundled translation,
    /// or `""` if it can't be loaded (the dispatch then degrades to citation-only
    /// rather than failing).
    private func chapterSnapshot(bookId: String, chapterNumber: Int) -> String {
        guard let chapter = (try? textLoader.loadChapter(
            bookId: bookId, chapterNumber: chapterNumber, translation: translation
        )) ?? nil else { return "" }
        return BibleVerseTextFormatter.numbered(chapter.coalescedVerses())
    }

    // MARK: - Test seam

    /// Await the current work loop and all issued ledger writes to settle
    /// (completed, halted, paused, or cancelled). Lets tests drive the engine
    /// deterministically with no sleeps. Underscore-prefixed per the test-only
    /// seam convention (AGENTS.md §Testing).
    func _waitUntilIdle() async {
        await driver?.value
        await lastWrite?.value
    }
}
