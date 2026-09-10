import Core
import SwiftUI

struct BulkAnnotationHubScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    @Bindable var viewModel: BulkAnnotationViewModel
    let coverage: AnnotationCoverage
    /// Remote BYOK generation requires confirmation; free on-device generation can start directly.
    let requiresCostConfirmation: Bool
    var finishedRuns: [FinishedRunSummary] = []

    // One sheet item keeps Generate and Progress mutually exclusive.
    private enum ActiveSheet: Identifiable {
        case generate, progress
        var id: Self { self }
    }
    @State private var activeSheet: ActiveSheet?
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            AnnotationCoverageCard(coverage: coverage)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            if let run = viewModel.run {
                runningSection(run)
            } else {
                idleSection
            }

            if !finishedRuns.isEmpty {
                finishedSection
                    .padding(.top, 22)
            }

            Spacer(minLength: 24)

            BulkDangerButton(title: "Delete all annotations", systemImage: "trash") {
                confirmDeleteAll = true
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(theme.background)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .generate:
                GenerateAnnotationsSheet(viewModel: viewModel, requiresCostConfirmation: requiresCostConfirmation)
            case .progress:
                BulkAnnotationProgressScreen(viewModel: viewModel)
            }
        }
        .alert("Delete all annotations?", isPresented: $confirmDeleteAll) {
            Button("Delete", role: .destructive) { viewModel.confirmDeleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every annotation across the whole Bible. This can't be undone.")
        }
    }

    @ViewBuilder
    private var idleSection: some View {
        VStack(spacing: 9) {
            BulkPrimaryButton(title: "Generate annotations", systemImage: "sparkles") {
                activeSheet = .generate
            }
            Text("Pick books and chapters to annotate. Runs in the background — keep reading while it works.")
                .font(typography.font(.caption))
                .foregroundStyle(theme.inkFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func runningSection(_ run: BulkRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("IN PROGRESS")
                .font(typography.mono(10.5, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            BulkJobCard(
                snapshot: run,
                onOpen: { activeSheet = .progress },
                onTogglePause: { viewModel.togglePause() }
            )
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var finishedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENTLY FINISHED")
                .font(typography.mono(10.5, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 20)

            VStack(spacing: 8) {
                ForEach(finishedRuns) { summary in
                    BulkFinishedRunRow(
                        summary: summary,
                        onRetry: { viewModel.retryFinishedRun(summary.runID) },
                        onDismiss: { viewModel.dismissFinishedRun(summary.runID) }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
