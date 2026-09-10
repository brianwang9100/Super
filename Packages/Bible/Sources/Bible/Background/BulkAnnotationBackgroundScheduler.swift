import Foundation
import os

private let bulkBackgroundLog = Logger(subsystem: "com.brianwang.Super", category: "bible-bulk-bg")

/// Shares the foreground runner during granted background time. Supports suspended
/// apps; terminated apps restore on their next foreground launch.
@MainActor
public final class BulkAnnotationBackgroundScheduler {
    /// Must match BGTaskSchedulerPermittedIdentifiers in the SuperBible target.
    public static let taskIdentifier = "com.brianwang.SuperBible.bulk-annotation"

    private let runner: BulkAnnotationRunner
    private let ledger: any BulkAnnotationLedger
    private let system: any BulkBackgroundTaskScheduling

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

    /// Schedules while work remains, otherwise cancels. Requires network, but not external power.
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
                // Background submission is best-effort and unavailable on the simulator.
                // Foreground execution remains available if submission fails.
                bulkBackgroundLog.debug("submit failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            system.cancel(identifier: Self.taskIdentifier)
        }
    }

    public func applicationDidBecomeActive() {
        runner.resumeActiveRun()
    }

    /// Completes on natural drain or expiration, whichever wins. Expiration requeues and
    /// flushes the in-flight unit immediately: waiting for LLM generation would exceed
    /// the remaining background time. The abandoned generation result is discarded.
    public func handle(_ task: any BulkBackgroundTask) async {
        expirationRequested = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceContinuation(continuation)

            task.expirationHandler = { [weak self] in
                // Registered on .main; assert isolation to requeue without an await gap.
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

        // Prevent a late expiration from changing success after natural drain won.
        task.expirationHandler = nil

        let workRemains = await hasPendingWork()
        task.setTaskCompleted(success: !expirationRequested)
        if workRemains {
            await scheduleIfNeeded()
        }
    }

    // Paused runs cannot advance; counting them would repeatedly schedule empty background tasks.
    private func hasPendingWork() async -> Bool {
        ((try? await ledger.activeRun()) ?? nil)?.status == .running
    }
}

/// Main-actor confinement makes racing completion paths safe without a lock.
@MainActor
private final class OnceContinuation {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func fire() {
        continuation?.resume()
        continuation = nil
    }
}
