import Foundation

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
            try? system.submit(
                BulkBackgroundTaskRequest(
                    identifier: Self.taskIdentifier,
                    requiresNetworkConnectivity: true,
                    requiresExternalPower: false
                )
            )
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

    /// Drive the active run for as long as the system grants `task`. Installs an
    /// expiration handler that asks the engine to wind down gracefully (finishing
    /// the in-flight unit, then stopping before the next), awaits the loop,
    /// marks the task complete, and reschedules if work still remains so iOS
    /// wakes us again to continue.
    public func handle(_ task: any BulkBackgroundTask) async {
        expirationRequested = false
        task.expirationHandler = { [weak self] in
            // The system invokes this on the queue the launch handler was
            // registered on (`.main`); assert that isolation so the engine call
            // is a synchronous main-actor hop with no await gap.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expirationRequested = true
                self.runner.requestBackgroundStop()
            }
        }

        await runner.runInBackground()

        let workRemains = await hasPendingWork()
        task.setTaskCompleted(success: !expirationRequested)
        if workRemains {
            await scheduleIfNeeded()
        }
    }

    /// A run is still active (`status` running or paused) — `activeRun()` only
    /// ever returns a non-terminal run, so this is `false` once the run completes,
    /// halts, or is cancelled.
    private func hasPendingWork() async -> Bool {
        ((try? await ledger.activeRun()) ?? nil) != nil
    }
}
