import Core
import SwiftUI

/// The Annotations hub — the single home for bulk generation, reached from
/// Settings → Annotations. A coverage synopsis on top, then either a Generate
/// CTA (idle) or the one active job (running), and a destructive
/// "Delete all annotations" at the bottom.
///
/// Coverage is passed in (the container binds it via `@Query` over
/// `AnnotationCoverageRequest`) so this screen stays render-only and
/// snapshot-testable.
struct BulkAnnotationHubScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    @Bindable var viewModel: BulkAnnotationViewModel
    let coverage: AnnotationCoverage
    /// `true` for a remote BYOK model (Generate asks for confirmation first);
    /// `false` for the free on-device model (Generate starts directly).
    let requiresCostConfirmation: Bool

    /// The two surfaces are mutually exclusive, so one `.sheet(item:)` drives
    /// both rather than two `isPresented` sheets stacked on one view.
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
}
