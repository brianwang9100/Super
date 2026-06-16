# PR-10: BGTask expiration re-queues the in-flight unit (closes P1-5; drive-bys P3-28, P3-29)

> **For agentic workers:** implement task-by-task; each task is TDD (fail-first test → minimal impl → green).

**Goal:** When a Bible bulk-annotation `BGProcessingTask` runs out of time mid-generation, return the in-flight unit to the queue *immediately* (instead of waiting out a 10–60 s LLM call), flush that write, and mark the task complete inside iOS's grace window — so the app isn't watchdog-killed, no spend is stranded as a wedged `.generating` row, and the system keeps granting future background time.

**Architecture:** The scheduler's expiration handler currently only sets a flag the loop checks *before the next unit*, then `await runner.runInBackground()` blocks until the in-flight `generate(...)` returns — which can be far longer than iOS's post-expiration grace. New model: the expiration handler synchronously re-queues the in-flight unit and latches the run so the loop discards the abandoned call's eventual outcome; `handle` then owns completion (a one-shot race between the run draining naturally and the expiration path) rather than waiting for `runInBackground()` to return.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, `os.Logger`, `BackgroundTasks` (iOS-only, seam-abstracted for `swift test`).

---

## Findings

- **P1-5** — `BulkAnnotationBackgroundScheduler.handle` installs an `expirationHandler` that calls `runner.requestBackgroundStop()`, which only sets `backgroundStopRequested` (checked at the *top* of the loop, before the next unit). The in-flight `await generator.generate(reference:)` keeps running, and `setTaskCompleted` is only called after `runInBackground()` returns — i.e. after that LLM call finishes. iOS terminates the process a few seconds after expiration, so a mid-generate expiration likely: kills the app, loses the in-flight generation, leaves `setTaskCompleted` uncalled (system deprioritizes future grants), and strands the unit `.generating`. Recoverable via `restore()` on next launch (so reliability, not data loss).
- **P3-28** (drive-by) — `BulkAnnotationBackgroundController.applicationDidEnterBackground` fires a bare `Task { await scheduler.scheduleIfNeeded() }` that races app suspension (the `BGTaskScheduler.submit` may not land before the app suspends), and the scheduler's submit-failure path uses a `#if DEBUG print` instead of the applet's `os.Logger`.
- **P3-29** (drive-by) — every ledger write in the runner is a silent `try?` (`enqueueWrite` closures, `saveUnit`, the direct-await writes in `restore`/`adoptFinished`/`persistThenRun`), so a failing disk leaves the in-memory mirror and the durable ledger divergent with no breadcrumb.

## Design

### The new expiration contract (P1-5)

**`BulkAnnotationRunner`:**

- Replace `requestBackgroundStop()` with **`requestExpirationStop()`** — *synchronous*, so when the scheduler's expiration handler returns, the re-queue has already happened (no Task-ordering race against the test driver):
  - set `backgroundStopRequested = true` (the loop still stops before the next unit, as today);
  - find the unit currently `.generating`; if one exists, set it back to `.queued`, bump `updatedAt`, `saveUnit(at:)` it, set a new latch `expirationAbandoned = true`, and `projectSnapshot()`. (No in-flight unit → just the flag; the top-of-loop guard stops it.)
- Add **`expirationAbandoned`** (`Bool`), cleared at the top of every fresh `runLoop` (next to the existing `backgroundStopRequested = false`). In `runLoop`, immediately after `await generator.generate(...)` and the existing `if runRecord == nil { return }` (cancel) guard, add: `if expirationAbandoned { return }` — discards the abandoned call's outcome with **no further write** (the unit was already re-queued), so nothing lands after the task completes.
- Add **`flushPendingWrites() async`** = `await lastWrite?.value` — the scheduler awaits it so the re-queue write is durable before `setTaskCompleted`.
- `runInBackground()` is **unchanged** (still `restore()` → `resumeActiveRun()` → `await driver?.value` → `await lastWrite?.value`) — it remains the natural-drain path.

**`BulkAnnotationBackgroundScheduler.handle`** — own completion via a one-shot continuation raced between the natural drain and the expiration path:

```swift
public func handle(_ task: any BulkBackgroundTask) async {
    expirationRequested = false
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let once = OnceContinuation(continuation)
        task.expirationHandler = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { once.fire(); return }
                self.expirationRequested = true
                self.runner.requestExpirationStop()          // synchronous re-queue
                Task { @MainActor in
                    await self.runner.flushPendingWrites()   // re-queue write durable
                    once.fire()                              // complete now — don't await the abandoned generate
                }
            }
        }
        Task { @MainActor in
            await self.runner.runInBackground()              // natural drain
            once.fire()
        }
    }
    let workRemains = await hasPendingWork()
    task.setTaskCompleted(success: !expirationRequested)
    if workRemains { await scheduleIfNeeded() }
}
```

`OnceContinuation` is a tiny `@MainActor private final class` that resumes its continuation at most once (lock-free — both fire sites are main-actor). The expiration path no longer waits on the stuck driver; the `runInBackground` Task simply completes later (when the abandoned generate returns and the loop's `expirationAbandoned` guard returns) and its `once.fire()` is a no-op. Salvage of a generate that *already finished* at expiration time is preserved for free: `requestExpirationStop` only re-queues a unit still `.generating`; one that just landed `.done` is left alone.

Update the `handle` / `requestExpirationStop` doc comments (they currently say "finishing the in-flight unit, then stopping before the next").

### Drive-bys

- **P3-28** — in `applicationDidEnterBackground`, under `#if canImport(UIKit)`, wrap the scheduling `Task` in `UIApplication.shared.beginBackgroundTask(withName:)` / `endBackgroundTask` so iOS grants time for `submit` to land before suspension; `#else` keeps the bare `Task`. Replace the scheduler's `#if DEBUG print(...)` with a file-scope `os.Logger` (`subsystem: "com.brianwang.Super", category: "bible-bulk-bg"`, mirroring `BibleApplet`'s `bibleAppletLog`) at `.debug` (the submit benignly throws on the simulator).
- **P3-29** — convert `enqueueWrite` to take `@Sendable () async throws -> Void` and `catch`+`log.error` inside its serialized Task; drop the `try?` at every call site (now `try await ledger.save…`). Wrap the direct-await writes in `restore`/`adoptFinished`/`persistThenRun` (and the `createRun` undo `deleteRun`) with a `performLogged(_:_: )` helper that `do/catch`+logs. Reads (`ledger.run`/`units`/`activeRun`) keep their `try?` (the audit scopes this to *writes*).

## Files

- **Modify:** `Packages/Bible/Sources/Bible/ViewModels/BulkAnnotationRunner+Live.swift` — `import os` + file-scope `Logger`; `requestBackgroundStop` → `requestExpirationStop`; `expirationAbandoned` field + loop guard + `runLoop`-start reset; `flushPendingWrites()`; throwing+logged `enqueueWrite`; `performLogged` for direct writes.
- **Modify:** `Packages/Bible/Sources/Bible/Background/BulkAnnotationBackgroundScheduler.swift` — `import os` + `Logger`; `handle` restructure + `OnceContinuation`; call `requestExpirationStop`; drop `expirationRequested`-only flag plumbing that's now redundant (keep `expirationRequested` for the `success:` value); Logger replaces `print`.
- **Modify:** `Packages/Bible/Sources/Bible/Background/BulkAnnotationBackgroundController.swift` — `beginBackgroundTask` wrap.
- **Modify (tests):** `Packages/Bible/Tests/BibleTests/Background/BulkAnnotationBackgroundSchedulerTests.swift` — new fail-first force-requeue test; rewrite `expirationStopsAfterTheCurrentUnitAndReschedules` → `expirationReQueuesTheInFlightUnitAndReschedules`; rewrite `applicationDidBecomeActiveResumesABackgroundStoppedRun` for the re-queue contract (the in-flight unit re-runs on resume).

## TDD tasks

### Task 1 — Fail-first: force-requeue on expiration
- [ ] Add `forceRequeuesInFlightUnitOnExpirationAndCompletesPromptly`: `runner.start(plan([1,2]))`; `handling = Task { scheduler.handle(task) }`; `await generator.awaitCall()` (unit 1 in flight); `task.expire()`; `await handling.value`. Before releasing the generate, assert `units[0].state == .queued`, `units[1].state == .queued`, `run.status == .running`, `task.completedSuccess == false`, `system.submitted.count == 1`. Then `generator.releaseNext(.success(99))`, `await runner._waitUntilIdle()`, and assert `units[0].state == .queued` still (abandoned outcome discarded — **no write after completion**).
- [ ] Run against current code → it hangs at `await handling.value` (old `handle` blocks on the un-released generate): the bug, demonstrated.

### Task 2 — Implement runner expiration-requeue
- [ ] `expirationAbandoned` field; `requestExpirationStop()`; loop guard; `runLoop`-start reset; `flushPendingWrites()`. Build `swift build`.

### Task 3 — Implement scheduler `handle` restructure
- [ ] `OnceContinuation`; `handle` race; call `requestExpirationStop` + `flushPendingWrites`. Task 1 test now passes.

### Task 4 — Rewrite the two existing expiration/resume tests
- [ ] `expirationReQueuesTheInFlightUnitAndReschedules`: expire mid-unit-2 → unit 2 `.queued` (not `.done`), unit 1 `.done`, unit 3 `.queued`, run `.running`, success false, submitted 1.
- [ ] `applicationDidBecomeActiveResumesABackgroundStoppedRun`: `requestExpirationStop()` mid-unit-1 → unit 1 `.queued`; foreground resume re-generates unit 1 then unit 2 → run `.completed`.

### Task 5 — Drive-bys P3-28 / P3-29
- [ ] Controller `beginBackgroundTask` wrap; scheduler Logger; runner throwing+logged `enqueueWrite` + `performLogged`. Build clean.

### Task 6 — Verify + review + PR
- [ ] `swift test -Xswiftc -warnings-as-errors` green in `Packages/Bible`. Adversarial review subagent → fix MUST/SHOULD. PR with Test Coverage. claude-review → APPROVE → squash auto-merge → STOP.

## Verification

`swift test -Xswiftc -warnings-as-errors` from `Packages/Bible/` (no UIKit/snapshot legs touched; the controller's `beginBackgroundTask` is `#if canImport(UIKit)` so the macOS `swift test` build takes the `#else`). No snapshot baselines change (no view edits). The iOS snapshot CI leg is unaffected.

## Out of scope

Cold-launch-in-background (the engine's documented out-of-scope case; resumes via `restore()` on next foreground). SuperOS has no bulk-annotation background wiring today. No new public API beyond the renamed/added runner methods.

## Workflow

Built in the `pr5-privacy-manifests` worktree dir on branch `worktree-pr10-bible-bgtask` off `origin/main` (the block-outside-worktree hook pins writes to this worktree root). Review subagent → fix MUST/SHOULD → PR with Test Coverage → claude-review APPROVE → squash auto-merge → STOP.
