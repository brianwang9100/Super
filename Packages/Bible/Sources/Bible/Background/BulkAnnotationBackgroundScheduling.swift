import Foundation

#if canImport(UIKit)
import BackgroundTasks
#endif

// Isolate BackgroundTasks behind seams usable by macOS logic tests.

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

public protocol BulkBackgroundTaskScheduling: Sendable {
    func submit(_ request: BulkBackgroundTaskRequest) throws
    func cancel(identifier: String)
}

/// Expiration is delivered on the main queue registered by the launch handler.
@MainActor
public protocol BulkBackgroundTask: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

#if canImport(UIKit)

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

/// Background execution is iOS-only; non-UIKit builds use no-op adapters.
public struct SystemBulkBackgroundTaskScheduler: BulkBackgroundTaskScheduling {
    public init() {}
    public func submit(_ request: BulkBackgroundTaskRequest) throws {}
    public func cancel(identifier: String) {}
}

#endif
