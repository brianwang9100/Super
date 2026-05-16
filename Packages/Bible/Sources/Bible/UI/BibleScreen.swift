import Core
import SwiftUI

/// The Bible reading surface: a floating nav bar over a scrolling column of
/// heading, prose, and poetry paragraphs, ending in prev / next cards.
///
/// All chapter and selection state lives in `BibleScreenViewModel`; the view
/// reads it and renders. The chapter text loads synchronously, so a step
/// repaints at once — only the persisted reading position is written
/// asynchronously. Tapping verses drives the action sheet; the `+` button and
/// the action sheet's chat actions are deferred stubs that raise a toast.
public struct BibleScreen: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let viewModel: BibleScreenViewModel

    /// How sheets, the action sheet, and the toast animate in and out — a
    /// bottom slide by default, a cross-fade when Reduce Motion is on.
    private var motion: BibleSheetMotion { BibleSheetMotion(reduceMotion: reduceMotion) }

    /// Space at the bottom reserved for the shell's minimized chat pill —
    /// the action sheet and toast both clear it.
    private let bottomReserve: CGFloat = 84

    public init(viewModel: BibleScreenViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()
            content
            navBar
            bottomOverlay
            if let bookSheet = viewModel.bookSheet {
                bookPicker(bookSheet)
            }
            if viewModel.isTranslationSheetPresented {
                translationPicker
            }
            if let toast = viewModel.toast {
                BibleAttachToast(
                    message: toast,
                    onDismiss: { withAnimation(motion.animation) { viewModel.dismissToast() } }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, bottomReserve)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(motion.transition)
            }
        }
        .task { await viewModel.load() }
    }

    private var navBar: some View {
        BibleNavBar(
            bookName: viewModel.bookName,
            chapterNumber: viewModel.position.chapterNumber,
            translation: viewModel.translation,
            selectionCitation: viewModel.selectionCitation,
            canStepBackward: viewModel.canStepBackward,
            canStepForward: viewModel.canStepForward,
            onPrevious: { viewModel.stepChapter(.previous) },
            onNext: { viewModel.stepChapter(.next) },
            onPill: { withAnimation(motion.animation) { viewModel.presentBookSheet() } },
            onTranslation: { withAnimation(motion.animation) { viewModel.presentTranslationSheet() } },
            onClearSelection: { withAnimation(motion.animation) { viewModel.clearSelection() } },
            onPlus: { withAnimation(motion.animation) { viewModel.presentChatComingSoon() } }
        )
    }

    /// The selection action sheet, anchored above the shell's chat pill while
    /// verses are selected.
    @ViewBuilder
    private var bottomOverlay: some View {
        if !viewModel.selectedVerses.isEmpty {
            BibleActionSheet(
                citation: viewModel.selectionCitation ?? "",
                shareText: viewModel.selectionShareText ?? "",
                onHighlight: { color in withAnimation(motion.animation) { viewModel.applyHighlight(color) } },
                onClearHighlight: { withAnimation(motion.animation) { viewModel.clearHighlight() } },
                onCopy: { withAnimation(motion.animation) { viewModel.copySelection() } },
                onAddToChat: { withAnimation(motion.animation) { viewModel.presentChatComingSoon() } },
                onNewChat: { withAnimation(motion.animation) { viewModel.presentChatComingSoon() } },
                onClose: { withAnimation(motion.animation) { viewModel.clearSelection() } }
            )
            .padding(.bottom, bottomReserve)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .transition(motion.transition)
        }
    }

    /// A dimmed backdrop plus the translation picker. The picker is a short
    /// sheet — it sizes to its three rows and anchors to the bottom edge.
    @ViewBuilder
    private var translationPicker: some View {
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(motion.animation) { viewModel.dismissTranslationSheet() } }
            .transition(.opacity)

        BibleTranslationSheet(
            current: viewModel.translation,
            // Lift the sheet's last row above the shell's minimized chat
            // pill, mirroring the reader's 76pt bottom reserve.
            bottomInset: 76,
            onSelect: { translation in
                withAnimation(motion.animation) { viewModel.selectTranslation(translation) }
            },
            onClose: { withAnimation(motion.animation) { viewModel.dismissTranslationSheet() } }
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(motion.transition)
    }

    /// A dimmed backdrop plus the book picker, inset from the top so a sliver
    /// of the reader stays visible behind it. The backdrop fades and the
    /// sheet slides up from the bottom edge.
    @ViewBuilder
    private func bookPicker(_ sheetViewModel: BibleBookSheetViewModel) -> some View {
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(motion.animation) { viewModel.dismissBookSheet() } }
            .transition(.opacity)

        BibleBookSheet(
            viewModel: sheetViewModel,
            currentBookId: viewModel.position.bookId,
            currentChapterNumber: viewModel.position.chapterNumber,
            // Lift the order toggle above the shell's minimized chat pill,
            // mirroring the reader's 76pt bottom reserve.
            bottomInset: 76,
            onSelectChapter: { bookId, chapterNumber in
                withAnimation(motion.animation) {
                    viewModel.selectChapter(bookId: bookId, chapterNumber: chapterNumber)
                }
            },
            onClose: { withAnimation(motion.animation) { viewModel.dismissBookSheet() } }
        )
        .padding(.top, 80)
        .transition(motion.transition)
    }

    @ViewBuilder
    private var content: some View {
        if let chapter = viewModel.chapter, !chapter.paragraphs.isEmpty {
            BibleChapterReader(
                chapter: chapter,
                bookId: viewModel.position.bookId,
                bookName: viewModel.bookName,
                selectedVerses: viewModel.selectedVerses,
                previousLabel: viewModel.previousChapterLabel,
                nextLabel: viewModel.nextChapterLabel,
                onTapVerse: { number in
                    withAnimation(motion.animation) { viewModel.toggleVerse(number) }
                },
                onPrevious: { viewModel.stepChapter(.previous) },
                onNext: { viewModel.stepChapter(.next) },
                onClearSelection: {
                    withAnimation(motion.animation) { viewModel.clearSelection() }
                }
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
                .font(.system(.headline, design: .serif))
                .foregroundStyle(theme.inkSoft)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    BibleScreen(viewModel: BibleScreenViewModel(textLoader: BundledBibleTextLoader()))
        .superTheme(.make(.light))
}
