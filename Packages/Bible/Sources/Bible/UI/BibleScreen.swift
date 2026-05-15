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
        }
        .task { await viewModel.load() }
    }

    private var navBar: some View {
        BibleNavBar(
            bookName: viewModel.bookName,
            chapterNumber: viewModel.position.chapterNumber,
            translationId: viewModel.translationId,
            canStepBackward: viewModel.canStepBackward,
            canStepForward: viewModel.canStepForward,
            onPrevious: { viewModel.stepChapter(.previous) },
            onNext: { viewModel.stepChapter(.next) },
            onPill: { viewModel.presentBookSheet() },
            onPlus: {}
        )
    }

    /// A dimmed backdrop plus the book picker, inset from the top so a sliver
    /// of the reader stays visible behind it.
    @ViewBuilder
    private func bookPicker(_ sheetViewModel: BibleBookSheetViewModel) -> some View {
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { viewModel.dismissBookSheet() }

        BibleBookSheet(
            viewModel: sheetViewModel,
            currentBookId: viewModel.position.bookId,
            currentChapterNumber: viewModel.position.chapterNumber,
            // Lift the order toggle above the shell's minimized chat pill,
            // mirroring the reader's 76pt bottom reserve.
            bottomInset: 76,
            onSelectChapter: { bookId, chapterNumber in
                viewModel.selectChapter(bookId: bookId, chapterNumber: chapterNumber)
            },
            onClose: { viewModel.dismissBookSheet() }
        )
        .padding(.top, 80)
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
