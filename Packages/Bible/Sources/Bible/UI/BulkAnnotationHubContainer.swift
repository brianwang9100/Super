import Core
import GRDBQuery
import SwiftUI

/// The factory supplies Bible's database context, overriding the surrounding Chat Settings context.
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
        // Seed the presented sheet's imperative badge state on first appearance and after query updates.
        .onChange(of: annotatedChapters, initial: true) { _, chapters in
            viewModel.updateDoneState(annotatedChapters: chapters)
        }
    }
}
