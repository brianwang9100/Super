import Core
import SwiftUI

/// Per-book progress for the active job: a summary header (ring · annotation
/// count · pause/cancel) over a scrollable chapter list. Failures isolate to
/// their chapter — a banner offers "Retry all" and each failed row its own
/// Retry — they never restart the run.
struct BulkAnnotationProgressScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: BulkAnnotationViewModel

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: "Generating", sizing: .expandable, onClose: { dismiss() })

            if let book = viewModel.activeBook {
                summaryHeader(book)
                if book.failedCount > 0 { failureBanner(book.failedCount) }
                chapterList(book)
            } else {
                Spacer()
                Text("No active job")
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.inkFaint)
                Spacer()
            }
        }
        .background(theme.background)
        .sheetPresentation(.expandable)
    }

    @ViewBuilder
    private func summaryHeader(_ book: BulkBookProgress) -> some View {
        HStack(spacing: 16) {
            BulkProgressRing(value: book.fractionComplete, size: 54, stroke: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int((book.fractionComplete * 100).rounded()))")
                        .font(typography.font(.subheadline, weight: .bold))
                        .monospacedDigit()
                    Text("%").font(typography.font(.caption2, weight: .semibold))
                }
                .foregroundStyle(theme.ink)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(book.name)
                    .font(typography.font(.headline, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text("\(book.producedCount) of ~\(book.estimatedTotal) annotations")
                    .font(typography.mono(11.5))
                    .foregroundStyle(theme.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                BulkRoundIconButton(
                    systemName: (viewModel.run?.isRunning ?? false) ? "pause.fill" : "play.fill",
                    accessibilityLabel: (viewModel.run?.isRunning ?? false) ? "Pause" : "Resume"
                ) { viewModel.togglePause() }
                BulkRoundIconButton(systemName: "xmark", accessibilityLabel: "Cancel") {
                    viewModel.cancelRun()
                    dismiss()
                }
            }
        }
        .padding(16)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.borderFaint).frame(height: 0.5) }
    }

    @ViewBuilder
    private func failureBanner(_ count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(typography.font(size: 16))
            Text("\(count) \(count == 1 ? "chapter" : "chapters") couldn't be generated")
                .font(typography.font(.footnote, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry all") { viewModel.retryAllFailed() }
                .font(typography.font(.caption, weight: .bold))
                .buttonStyle(.plain)
        }
        .foregroundStyle(theme.errorInk)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.errorBackground))
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func chapterList(_ book: BulkBookProgress) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(book.chapters) { chapter in
                    BulkChapterRow(bookName: book.name, chapter: chapter) {
                        viewModel.retry(ChapterRef(bookID: book.bookID, number: chapter.number))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}
