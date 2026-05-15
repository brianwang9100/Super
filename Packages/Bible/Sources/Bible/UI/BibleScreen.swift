import Core
import SwiftUI

/// The Bible reading surface: a floating nav bar over a scrolling column of
/// heading, prose, and poetry paragraphs, ending in prev / next cards.
///
/// All chapter state lives in `BibleScreenViewModel`; the view reads it and
/// renders. The chapter text loads synchronously, so a step repaints at
/// once — only the persisted reading position is written asynchronously.
public struct BibleScreen: View {
    @Environment(\.superTheme) private var theme
    private let viewModel: BibleScreenViewModel

    /// Drives the book and translation pickers' slide-up / slide-down — a
    /// smooth decel curve close to the design's `cubic-bezier(0.32, 0.72, 0, 1)`.
    private let sheetAnimation: Animation = .snappy(duration: 0.34)

    public init(viewModel: BibleScreenViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()
            content
            navBar
            if let bookSheet = viewModel.bookSheet {
                bookPicker(bookSheet)
            }
            if viewModel.isTranslationSheetPresented {
                translationPicker
            }
        }
        .task { await viewModel.load() }
    }

    private var navBar: some View {
        BibleNavBar(
            bookName: viewModel.bookName,
            chapterNumber: viewModel.position.chapterNumber,
            translation: viewModel.translation,
            canStepBackward: viewModel.canStepBackward,
            canStepForward: viewModel.canStepForward,
            onPrevious: { viewModel.stepChapter(.previous) },
            onNext: { viewModel.stepChapter(.next) },
            onPill: { withAnimation(sheetAnimation) { viewModel.presentBookSheet() } },
            onTranslation: { withAnimation(sheetAnimation) { viewModel.presentTranslationSheet() } },
            onPlus: {}
        )
    }

    /// A dimmed backdrop plus the translation picker. The picker is a short
    /// sheet — it sizes to its three rows and anchors to the bottom edge.
    @ViewBuilder
    private var translationPicker: some View {
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(sheetAnimation) { viewModel.dismissTranslationSheet() } }
            .transition(.opacity)

        BibleTranslationSheet(
            current: viewModel.translation,
            // Lift the sheet's last row above the shell's minimized chat
            // pill, mirroring the reader's 76pt bottom reserve.
            bottomInset: 76,
            onSelect: { translation in
                withAnimation(sheetAnimation) { viewModel.selectTranslation(translation) }
            },
            onClose: { withAnimation(sheetAnimation) { viewModel.dismissTranslationSheet() } }
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(.move(edge: .bottom))
    }

    /// A dimmed backdrop plus the book picker, inset from the top so a sliver
    /// of the reader stays visible behind it. The backdrop fades and the
    /// sheet slides up from the bottom edge.
    @ViewBuilder
    private func bookPicker(_ sheetViewModel: BibleBookSheetViewModel) -> some View {
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(sheetAnimation) { viewModel.dismissBookSheet() } }
            .transition(.opacity)

        BibleBookSheet(
            viewModel: sheetViewModel,
            currentBookId: viewModel.position.bookId,
            currentChapterNumber: viewModel.position.chapterNumber,
            // Lift the order toggle above the shell's minimized chat pill,
            // mirroring the reader's 76pt bottom reserve.
            bottomInset: 76,
            onSelectChapter: { bookId, chapterNumber in
                withAnimation(sheetAnimation) {
                    viewModel.selectChapter(bookId: bookId, chapterNumber: chapterNumber)
                }
            },
            onClose: { withAnimation(sheetAnimation) { viewModel.dismissBookSheet() } }
        )
        .padding(.top, 80)
        .transition(.move(edge: .bottom))
    }

    @ViewBuilder
    private var content: some View {
        if let chapter = viewModel.chapter, !chapter.paragraphs.isEmpty {
            reader(chapter)
        } else {
            unavailable
        }
    }

    private func reader(_ chapter: BibleChapter) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(viewModel.bookName) \(chapter.number)")
                    .font(.system(.largeTitle, design: .serif))
                    .italic()
                    .foregroundStyle(theme.ink)
                    .padding(.bottom, 6)

                ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    BibleParagraphBlock(paragraph: paragraph)
                }

                BibleChapterFooter(
                    previousLabel: viewModel.previousChapterLabel,
                    nextLabel: viewModel.nextChapterLabel,
                    onPrevious: { viewModel.stepChapter(.previous) },
                    onNext: { viewModel.stepChapter(.next) }
                )

                // Bottom inset so the chat overlay's minimized pill doesn't
                // obscure the footer — mirrors the shell's 76pt reserve.
                Color.clear.frame(height: 76)
            }
            .padding(.horizontal, 26)
            // Top inset clears the floating nav bar; the bar's gradient
            // fades over the first lines as they scroll up beneath it.
            .padding(.top, 68)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A fresh identity per chapter resets the scroll offset to the top
        // when the reader steps.
        .id(viewModel.position)
        // Swap chapters instantly even when the jump happens inside the
        // book picker's slide-down animation transaction.
        .transition(.identity)
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
