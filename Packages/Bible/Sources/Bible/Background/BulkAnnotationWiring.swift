import Core

/// The production bulk-annotation wiring `BibleApplet.makeBulkAnnotationWiring(…)`
/// hands back: the Settings hub contribution and the background scheduler, both
/// driving one shared `BulkAnnotationRunner`. The composition root drops the
/// contribution into the shell's settings and holds the scheduler for the app's
/// scene-phase glue.
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
