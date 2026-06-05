import Core
import GRDBQuery
import SwiftUI

/// Builds the **Annotations** entry the composition root contributes to the
/// shared Settings screen — the seam that lets Bible own a Settings pane
/// without Chat importing Bible (Chat renders the row + routes to the opaque
/// destination). The root binds the returned value into
/// `\.appletSettingsContributions`.
@MainActor
public enum BibleAnnotationsSettings {
    /// - Parameters:
    ///   - databaseContext: the **Bible** read-only context, applied to the hub
    ///     subtree so its coverage `@Query` reads `bible.sqlite`.
    ///   - runner: the bulk engine (the in-memory `FakeBulkAnnotationRunner`
    ///     until the LLM-backed runner lands).
    ///   - requiresCostConfirmation: `true` for a remote BYOK model (Generate
    ///     asks first), `false` for the free on-device model.
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
