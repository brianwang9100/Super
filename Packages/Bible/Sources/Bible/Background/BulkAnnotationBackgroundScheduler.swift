import Foundation
import os

private let bulkBackgroundLog = Logger(subsystem: "com.brianwang.Super", category: "bible-bulk-bg")

/// Keeps an active bulk-annotation run making progress while the app isn't
/// foregrounded, by riding a `BGProcessingTask`.
///
/// The engine (`BulkAnnotationRunner`) only advances while its work loop is
/// running, which freezes the moment iOS suspends the app. This scheduler:
///
/// - **schedules** a processing task when the app backgrounds with a run still
///   active (`scheduleIfNeeded()`), so iOS later grants background time;
/// - **drives** the run when that task fires (`handle(_:)`) — continuing the
///   loop until the run drains, halts, or the task runs out of time, then
///   marking the task complete and rescheduling if work remains;
/// - **resumes** a run the previous task stopped when the app returns to the
///   foreground (`applicationDidBecomeActive()`).
///
/// It drives the same `BulkAnnotationRunner` instance the Settings hub uses (the
/// composition root builds one runner and hands it to both), so foreground and
/// background never run two loops over the same ledger.
///
/// **Scope:** this covers the *suspended-app* case — the runner instance is
/// still alive when the task fires. A fully terminated app resumes its run on
/// the next foreground launch via the engine's `restore()`; relaunching the
/// whole dependency graph in the background is deliberately out of scope.
@MainActor
public final class BulkAnnotationBackgroundScheduler {
    /// The `BGTaskScheduler` identifier — must match the entry in
    /// `BGTaskSchedulerPermittedIdentifiers` (App-SuperBible `Info.plist`).
    public static let taskIdentifier = "com.brianwang.SuperBible.bulk-annotation"

    private let runner: BulkAnnotationRunner
    private let ledger: any BulkAnnotationLedger
    private let system: any BulkBackgroundTaskScheduling

    /// `true` when the in-flight task's `expirationHandler` fired, so `handle`
    /// reports the task incomplete (it was cut short, not finished). Reset at the
    /// start of each `handle`.
    private var expirationRequested = false

    public init(
        runner: BulkAnnotationRunner,
        ledger: any BulkAnnotationLedger,
        system: any BulkBackgroundTaskScheduling = SystemBulkBackgroundTaskScheduler()
    ) {
        self.runner = runner
        self.ledger = ledger
        self.system = system
    }

    /// Submit a processing-task request when a run is still active, or cancel any
    /// outstanding request when there's nothing left to do. Called when the app
    /// enters the background, and again after a background drain that expiration
    /// cut short.
    ///
    /// The request requires network connectivity (annotation generation hits the
    /// LLM) but not external power, so a run can advance on battery whenever iOS
    /// grants background time.
    public func scheduleIfNeeded() async {
        if await hasPendingWork() {
            do {
                try system.submit(
                    BulkBackgroundTaskRequest(
                        identifier: Self.taskIdentifier,
                        requiresNetworkConnectivity: true,
                        requiresExternalPower: false
                    )
                )
            } catch {
                // Best-effort (the run still drains whenever the app is
                // foregrounded). `submit` throwing means a misconfigured plist /
                // denied permission — and it always throws on the simulator, where
                // there's no background runtime — so log at `.debug` rather than
                // surfacing simulator noise as an error.
                bulkBackgroundLog.debug("submit failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            system.cancel(identifier: Self.taskIdentifier)
        }
    }

    /// The app returned to the foreground — restart a run a prior background-stop
    /// parked. No-op when nothing is parked (the common case: the foreground loop
    /// simply thawed and kept going).
    public func applicationDidBecomeActive() {
        runner.resumeActiveRun()
    }

    /// Drive the active run for as long as the system grants `task`, then mark it
    /// complete and reschedule if work remains. Completion is owned by a one-shot
    /// signal raced between two outcomes:
    ///
    /// - **natural drain** — `runInBackground()` returns (the run completed,
    ///   halted, or stopped before the next unit);
    /// - **expiration** — the system fires the expiration handler. iOS gives only
    ///   a few seconds afterward, far less than an in-flight LLM generation, so we
    ///   do *not* wait it out: `requestExpirationStop()` returns the in-flight unit
    ///   to the queue immediately, we flush that write so it's durable, then
    ///   complete the task — leaving the abandoned `generate` to finish (and be
    ///   discarded) on a loop that's no longer blocking us.
    ///
    /// Whichever fires first resolves the signal; the loser is a harmless no-op.
    public func handle(_ task: any BulkBackgroundTask) async {
        expirationRequested = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceContinuation(continuation)

            task.expirationHandler = { [weak self] in
                // The system invokes this on the queue the launch handler was
                // registered on (`.main`); assert that isolation so the engine
                // call is a synchronous main-actor hop with no await gap.
                MainActor.assumeIsolated {
                    guard let self else { once.fire(); return }
                    self.expirationRequested = true
                    self.runner.requestExpirationStop()  // synchronous re-queue of the in-flight unit
                    Task { @MainActor in
                        await self.runner.flushPendingWrites()  // re-queue durable before we complete
                        once.fire()
                    }
                }
            }

            Task { @MainActor in
                await self.runner.runInBackground()
                once.fire()
            }
        }

        // The race is resolved. Detach the expiration handler so a late expiration
        // (firing in the gap before `setTaskCompleted`) can't flip a run that
        // actually drained to `success: false`.
        task.expirationHandler = nil

        let workRemains = await hasPendingWork()
        task.setTaskCompleted(success: !expirationRequested)
        if workRemains {
            await scheduleIfNeeded()
        }
    }

    /// There's background work only when a run is actually `.running`.
    /// `activeRun()` also returns a `.paused` run, but a paused run can't advance
    /// in the background (`restore()` / `runInBackground()` deliberately don't
    /// start a loop for it) — counting it as pending would schedule a task that
    /// wakes, does nothing, and reschedules itself in an endless cycle. Once the
    /// run completes, halts, or is cancelled, `activeRun()` returns `nil`.
    private func hasPendingWork() async -> Bool {
        ((try? await ledger.activeRun()) ?? nil)?.status == .running
    }
}

/// Resumes a `CheckedContinuation` at most once, ignoring later fires. Lets
/// `handle` race two completion paths (natural drain vs. expiration) onto a
/// single continuation. Main-actor-confined, so the at-most-once guard needs no
/// lock.
@MainActor
private final class OnceContinuation {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func fire() {
        continuation?.resume()
        continuation = nil
    }
}
