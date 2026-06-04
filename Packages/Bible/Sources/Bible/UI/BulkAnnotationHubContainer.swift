import Core
import GRDBQuery
import SwiftUI

/// Binds whole-Bible annotation coverage reactively (so the card ticks up as a
/// run writes rows) and hands it to the render-only `BulkAnnotationHubScreen`.
/// The factory applies the **Bible** `DatabaseContext` to this subtree, so the
/// `@Query` reads `bible.sqlite` even though the surrounding Settings sheet
/// carries `chat.sqlite`.
public struct BulkAnnotationHubContainer: View {
    @Query(AnnotationCoverageRequest()) private var coverage: AnnotationCoverage
    @Query(FinishedRunsRequest()) private var finishedRuns: [FinishedRunSummary]
    @Query(AnnotatedChaptersRequest()) private var annotatedChapters: Set<ChapterRef>

    private let viewModel: BulkAnnotationViewModel
    private let requiresCostConfirmation: Bool

    public init(viewModel: BulkAnnotationViewModel, requiresCostConfirmation: Bool) {
        self.viewModel = viewModel
        self.requiresCostConfirmation = requiresCostConfirmation
    }

    public var body: some View {
        BulkAnnotationHubScreen(
            viewModel: viewModel,
            coverage: coverage,
            requiresCostConfirmation: requiresCostConfirmation,
            finishedRuns: finishedRuns
        )
        // Fold the annotated-chapters query into the view model's "Done" badges
        // (the Generate sheet reads them imperatively — it's presented as a sheet,
        // outside this container's `@Query` scope). `initial: true` seeds them on
        // first appearance so badges are correct before any write lands.
        .onChange(of: annotatedChapters, initial: true) { _, chapters in
            viewModel.updateDoneState(annotatedChapters: chapters)
        }
    }
}
