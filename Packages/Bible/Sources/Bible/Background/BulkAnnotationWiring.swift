import Core

/// Both consumers share one runner; retain the scheduler for app lifecycle forwarding.
@MainActor
public struct BulkAnnotationWiring {
    public let settingsContribution: AppletSettingsContribution
    public let background: BulkAnnotationBackgroundScheduler

    public init(
        settingsContribution: AppletSettingsContribution,
        background: BulkAnnotationBackgroundScheduler
    ) {
        self.settingsContribution = settingsContribution
        self.background = background
    }
}
