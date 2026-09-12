import Core
import SwiftUI

struct BibleBookWorkspace: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.fontResolutionContext) private var fontContext
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 24
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var numberSize: CGFloat = 13
    @Bindable var workspace: BibleReadingWorkspaceViewModel
    let topInset: CGFloat
    let onAnnotation: (BibleAnnotationTargetSpec, BibleTranslation) -> Void
    let onNote: (BibleNoteTargetSpec) -> Void
    var onBookmark: (BiblePosition) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            let scale = bodySize * typography.fontScale / 24
            let count = geometry.size.width >= 48 + 24 + 720 * max(1, scale) ? 2 : 1
            let width = max(0, (geometry.size.width - 48 - (count == 2 ? 24 : 0)) / CGFloat(count))
            let height = max(0, geometry.size.height - topInset - max(44, titleSize * typography.fontScale * 1.5) - 12 - 60)
            let style = BibleReadingWorkspaceViewModel.PaginationStyle(
                size: CGSize(width: width, height: height),
                body: typography.reading(bodySize, relativeTo: nil).resolve(in: fontContext),
                heading: typography.reading(bodySize * 1.15, relativeTo: nil, weight: .semibold).resolve(in: fontContext),
                number: typography.font(size: numberSize).resolve(in: fontContext)
            )
            VStack(spacing: 12) {
                if let error = workspace.pageError, workspace.visiblePages.isEmpty {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        Button("Retry") { workspace.retryPages() }.frame(minHeight: 44)
                    }
                    .font(typography.font(.body))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workspace.visiblePages.isEmpty {
                    ProgressView("Preparing pages")
                        .font(typography.font(.body))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BibleBookSpread(workspace: workspace, pageSize: style.size,
                                    onAnnotation: onAnnotation, onNote: onNote, onBookmark: onBookmark)
                        .id(workspace.visiblePages.map(\.position))
                    pageControls
                        .overlay(alignment: .top) {
                            if let error = workspace.pageError {
                                Button(error + " Retry") { workspace.retryPages() }
                                    .font(typography.font(.caption)).offset(y: -24)
                            }
                        }
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 24)
            .padding(.top, topInset)
            .onChange(of: style, initial: true) { _, style in workspace.updateLayout(style, pageCount: count) }
            .onChange(of: workspace.isRestoring) { _, restoring in
                if !restoring { workspace.updateLayout(style, pageCount: count) }
            }
            .onChange(of: count) { _, count in workspace.updateLayout(style, pageCount: count) }
            .onChange(of: workspace.reader.narration.currentVerseNumber) { _, _ in workspace.followNarration() }
        }
    }

    private var pageControls: some View {
        HStack {
            Button { workspace.turn(.previous) } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(!workspace.canTurnPrevious || workspace.isPaginating)
                .accessibilityLabel(workspace.pageCount == 2 ? "Previous pages" : "Previous page")
                .keyboardShortcut(.leftArrow, modifiers: [])
            Spacer()
            if workspace.isPaginating { ProgressView().accessibilityLabel("Preparing pages") }
            Button { workspace.turn(.next) } label: { Label("Next", systemImage: "chevron.right") }
                .disabled(!workspace.canTurnNext || workspace.isPaginating)
                .accessibilityLabel(workspace.pageCount == 2 ? "Next pages" : "Next page")
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .font(typography.font(.callout))
        .frame(minHeight: 44)
    }
}
