import Foundation

#if canImport(UIKit)
import BackgroundTasks
import UIKit
#endif

/// Register the launch handler during app init; attach the scheduler after async bootstrap.
/// An early task without a scheduler completes unsuccessfully and resumes on foreground launch.
@MainActor
public final class BulkAnnotationBackgroundController {
    private var scheduler: BulkAnnotationBackgroundScheduler?

    public init() {}

    /// Call once during app init, before the first scene. No-op off iOS.
    public func registerLaunchHandler() {
        #if canImport(UIKit)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BulkAnnotationBackgroundScheduler.taskIdentifier,
            using: .main
        ) { [weak self] task in
            // Registered on `.main`, so the handler runs on the main actor.
            MainActor.assumeIsolated {
                guard let scheduler = self?.scheduler else {
                    // Bootstrap is not ready; resume the persisted run on the next foreground launch.
                    task.setTaskCompleted(success: false)
                    return
                }
                let handle = SystemBulkBackgroundTask(task)
                Task { @MainActor in await scheduler.handle(handle) }
            }
        }
        #endif
    }

    public func attach(_ scheduler: BulkAnnotationBackgroundScheduler?) {
        self.scheduler = scheduler
    }

    public func applicationDidEnterBackground() {
        guard let scheduler else { return }
        #if canImport(UIKit)
        Task { @MainActor in
            // Hold a background assertion until submit finishes so suspension cannot prevent scheduling.
            let application = UIApplication.shared
            let assertionID = application.beginBackgroundTask(
                withName: "bulk-annotation-schedule", expirationHandler: nil
            )
            defer {
                if assertionID != .invalid { application.endBackgroundTask(assertionID) }
            }
            await scheduler.scheduleIfNeeded()
        }
        #else
        Task { await scheduler.scheduleIfNeeded() }
        #endif
    }

    public func applicationDidBecomeActive() {
        scheduler?.applicationDidBecomeActive()
    }
}
