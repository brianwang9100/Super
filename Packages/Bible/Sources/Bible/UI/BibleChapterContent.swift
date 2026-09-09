import Core
import SwiftUI

/// Binds local reading state to the reactive chapter column without shell or narration lifecycle effects.
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
                // Per spec: auto-scroll only when the user hasn't picked
                // a selection of their own.
                suppressNarrationScroll: !viewModel.selectedVerses.isEmpty,
                pendingScrollVerse: viewModel.pendingScrollVerse,
                // `bottomOverlayKind` tells the reader which sheet is up so its
                // paired selection scroll runs only for the action sheet —
                // lifting the just-selected verse clear of the sheet — while
                // narration's own follow-scroll stays the sole driver as it
                // plays. It also sizes the reader's bottom scroll reserve to the
                // presented sheet's height, so the last verses scroll clear of
                // the floating, scrim-less sheet instead of hiding behind it.
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
            // A fresh identity per chapter resets the scroll offset to the
            // top and re-subscribes the highlight `@Query` when the reader
            // steps.
            .id(viewModel.position)
            // Swap chapters instantly even when the jump happens inside the
            // book picker's slide-down animation transaction.
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
