import Core
import GRDBQuery
import SwiftUI

/// Contributes a Bible-owned Settings pane without a cross-applet import.
@MainActor
public enum BibleAnnotationsSettings {
    /// Supply Bible's read-only context for coverage queries. Require cost confirmation
    /// for remote BYOK generation; free on-device generation can start directly.
    public static func contribution(
        databaseContext: DatabaseContext,
        runner: any BulkAnnotationRunning,
        requiresCostConfirmation: Bool,
        deleteAll: @escaping @MainActor () -> Void = {}
    ) -> AppletSettingsContribution {
        let viewModel = BulkAnnotationViewModel(runner: runner, deleteAll: deleteAll)
        return AppletSettingsContribution(
            id: "bible.annotations",
            label: "Annotations",
            icon: AnyView(AnnotationBubble(state: .generating, size: 20)),
            destination: {
                AnyView(
                    BulkAnnotationHubContainer(
                        viewModel: viewModel,
                        requiresCostConfirmation: requiresCostConfirmation
                    )
                    .databaseContext(databaseContext)
                )
            }
        )
    }
}
