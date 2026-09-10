import Core
import SwiftUI

struct BibleChapterContent: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var unavailableSize: CGFloat = 17

    let viewModel: BibleScreenViewModel
    var layout: BibleChapterReaderLayout = .fullReader
    var navigation: BibleChapterNavigation?
    var overlayKind: BibleBottomOverlayKind?
    var currentNarratingVerse: Int?
    var onAnnotationBubbleTap: ((BibleAnnotationTargetSpec) -> Void)?
    var onRequestChapterAnnotation: ((BibleAnnotationTargetSpec) -> Void)?
    var onNoteGlyphTap: ((BibleNoteTargetSpec) -> Void)?
    var onBookmarkTap: (() -> Void)?
    var onScroll: (CGFloat, Bool) -> Void = { _, _ in }
    var onFooterVisible: (Bool) -> Void = { _ in }

    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    @ViewBuilder
    var body: some View {
        if let chapter = viewModel.chapter, !chapter.paragraphs.isEmpty {
            BibleChapterReader(
                chapter: chapter,
                bookId: viewModel.position.bookId,
                bookName: viewModel.bookName,
                selectedVerses: viewModel.selectedVerses,
                navigation: navigation,
                layout: layout,
                currentNarratingVerse: currentNarratingVerse,
                // Do not let narration auto-scroll override an active verse selection.
                suppressNarrationScroll: !viewModel.selectedVerses.isEmpty,
                pendingScrollVerse: viewModel.pendingScrollVerse,
                // Selection and narration use different scroll drivers; reserve the active sheet's height.
                bottomOverlayKind: overlayKind,
                onTapVerse: { number in
                    withAnimation(motion.animation) { viewModel.toggleVerse(number) }
                },
                onBackgroundTap: {
                    withAnimation(motion.animation) { viewModel.dismissActionSheet() }
                },
                onConsumeScroll: { _ = viewModel.consumePendingScrollVerse() },
                onAnnotationBubbleTap: onAnnotationBubbleTap,
                onRequestChapterAnnotation: onRequestChapterAnnotation,
                chapterDispatchStatus: viewModel.dispatchStatus(
                    for: viewModel.currentChapterAnnotationSpec
                ),
                onNoteGlyphTap: onNoteGlyphTap,
                onBookmarkTap: onBookmarkTap,
                onScroll: onScroll,
                onFooterVisible: onFooterVisible
            )
            // A chapter identity resets scroll position and the highlight query.
            .id(viewModel.position)
            // Do not inherit the book picker's dismissal animation.
            .transition(.identity)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            BibleAppletIcon(size: 40)
                .foregroundStyle(theme.inkFaint)
            Text("Chapter unavailable")
                .font(typography.font(size: unavailableSize, weight: .semibold, design: .serif))
                .foregroundStyle(theme.inkSoft)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
