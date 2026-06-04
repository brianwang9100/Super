import Foundation

#if canImport(UIKit)
import BackgroundTasks
#endif

/// The app-lifecycle glue around `BulkAnnotationBackgroundScheduler`: registers
/// the BGTask launch handler at process start and forwards scene-phase
/// transitions. Kept here (rather than in the app target) so all of the
/// `BackgroundTasks` plumbing lives inside Bible alongside the runner it drives,
/// and the app target only calls three plain methods.
///
/// The launch handler MUST be registered before the app finishes launching, but
/// the scheduler is built later by the async bootstrap. So this controller is
/// created and `registerLaunchHandler()`-ed in the app's `init`, then `attach`-ed
/// to the real scheduler once bootstrap completes. A task can only fire after a
/// run was started and the app backgrounded — by which point the scheduler is
/// attached — so the unattached window is harmless (a stray early fire simply
/// completes the task, and the run resumes on next foreground via the engine's
/// `restore()`).
@MainActor
public final class BulkAnnotationBackgroundController {
    private var scheduler: BulkAnnotationBackgroundScheduler?

    public init() {}

    /// Register the BGTask launch handler. Call once, from the app's `init`,
    /// before the first scene appears. No-op off iOS.
    public func registerLaunchHandler() {
        #if canImport(UIKit)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BulkAnnotationBackgroundScheduler.taskIdentifier,
            using: .main
        ) { [weak self] task in
            // Registered on `.main`, so the handler runs on the main actor.
            MainActor.assumeIsolated {
                guard let scheduler = self?.scheduler else {
                    // Fired before the graph was wired (e.g. a cold background
                    // launch — out of scope): nothing to drive. Complete it; the
                    // run resumes on the next foreground launch.
                    task.setTaskCompleted(success: false)
                    return
                }
                let handle = SystemBulkBackgroundTask(task)
                Task { @MainActor in await scheduler.handle(handle) }
            }
        }
        #endif
    }

    /// Hand the controller the real scheduler once bootstrap has built it.
    public func attach(_ scheduler: BulkAnnotationBackgroundScheduler?) {
        self.scheduler = scheduler
    }

    /// The app entered the background — schedule a processing task if a run is
    /// still active.
    public func applicationDidEnterBackground() {
        guard let scheduler else { return }
        Task { await scheduler.scheduleIfNeeded() }
    }

    /// The app returned to the foreground — resume a run a prior background task
    /// parked.
    public func applicationDidBecomeActive() {
        scheduler?.applicationDidBecomeActive()
    }
}
