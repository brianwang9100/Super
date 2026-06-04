import Foundation

#if canImport(UIKit)
import BackgroundTasks
#endif

/// The seams the bulk-annotation background scheduler drives, abstracted away
/// from the `BackgroundTasks` framework so the scheduling logic is unit-testable
/// on macOS (`swift test`, where `BackgroundTasks` isn't available) with fakes
/// and no sleeps. The thin `System…` adapters below wrap the real
/// `BGTaskScheduler` / `BGTask` and are exercised only by the app build +
/// on-device, never by the logic tests.

/// A scheduled processing-task request, mirroring the handful of
/// `BGProcessingTaskRequest` fields the runner needs.
public struct BulkBackgroundTaskRequest: Sendable, Equatable {
    public let identifier: String
    public let requiresNetworkConnectivity: Bool
    public let requiresExternalPower: Bool

    public init(
        identifier: String,
        requiresNetworkConnectivity: Bool,
        requiresExternalPower: Bool
    ) {
        self.identifier = identifier
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.requiresExternalPower = requiresExternalPower
    }
}

/// Submits / cancels background-task requests — the `BGTaskScheduler` surface the
/// scheduler talks to. A fake records calls in tests; `SystemBulkBackgroundTaskScheduler`
/// forwards to the real scheduler on-device.
public protocol BulkBackgroundTaskScheduling: Sendable {
    func submit(_ request: BulkBackgroundTaskRequest) throws
    func cancel(identifier: String)
}

/// A live background task the system handed us — the `BGTask` surface the
/// scheduler drives (install an expiration handler, mark complete). `@MainActor`
/// so the run engine it cooperates with stays on the main actor end to end.
@MainActor
public protocol BulkBackgroundTask: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

#if canImport(UIKit)

/// Forwards to the real `BGTaskScheduler` on-device. Stateless, so trivially
/// `Sendable`.
public struct SystemBulkBackgroundTaskScheduler: BulkBackgroundTaskScheduling {
    public init() {}

    public func submit(_ request: BulkBackgroundTaskRequest) throws {
        let bgRequest = BGProcessingTaskRequest(identifier: request.identifier)
        bgRequest.requiresNetworkConnectivity = request.requiresNetworkConnectivity
        bgRequest.requiresExternalPower = request.requiresExternalPower
        try BGTaskScheduler.shared.submit(bgRequest)
    }

    public func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Wraps the system `BGTask` the launch handler delivers. Only ever touched on
/// the main actor (the handler registers on `.main`).
@MainActor
final class SystemBulkBackgroundTask: BulkBackgroundTask {
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }

    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

#else

/// macOS / non-UIKit fallback so the default initializer argument and the
/// composition root still compile under `swift test`. Background execution is an
/// iOS-only capability, so these are no-ops.
public struct SystemBulkBackgroundTaskScheduler: BulkBackgroundTaskScheduling {
    public init() {}
    public func submit(_ request: BulkBackgroundTaskRequest) throws {}
    public func cancel(identifier: String) {}
}

#endif
