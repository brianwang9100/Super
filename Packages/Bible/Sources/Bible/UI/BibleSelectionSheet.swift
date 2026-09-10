import Core
import SwiftUI

struct BibleSelectionSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: BibleSelectionSheetViewModel
    @ScaledMetric(relativeTo: .subheadline) private var controlSize: CGFloat = 14
    @Namespace private var segmentNamespace

    let onSelect: () -> Void
    let onSelectTranslation: (BibleTranslation) -> Void
    let onClose: () -> Void
    let onPresentBookAnnotations: (String) -> Void
    let onRequestBookAnnotations: (String) -> Void
    let onPresentBookNotes: (String) -> Void
    var generatingBookIds: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: "Bible", sizing: .expandable, onClose: onClose)
            segments
            ZStack(alignment: .top) {
                bookPicker
                    .opacity(viewModel.tab == .book ? 1 : 0)
                    .allowsHitTesting(viewModel.tab == .book)
                    .accessibilityHidden(viewModel.tab != .book)
                ScrollView {
                    BibleTranslationSheet(
                        current: viewModel.translation, bottomInset: 0,
                        onSelect: onSelectTranslation, onClose: onClose,
                        isEmbedded: true
                    )
                }
                .opacity(viewModel.tab == .translation ? 1 : 0)
                .allowsHitTesting(viewModel.tab == .translation)
                .accessibilityHidden(viewModel.tab != .translation)
            }
            .frame(maxHeight: .infinity)
        }
        .background(theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.background)
    }

    private var bookPicker: some View {
        BibleBookSheet(
            viewModel: viewModel.bookPicker,
            currentBookId: viewModel.position.bookId,
            currentChapterNumber: viewModel.position.chapterNumber,
            onSelectChapter: { bookId, chapterNumber in
                viewModel.selectChapter(bookId: bookId, chapterNumber: chapterNumber)
                onSelect()
            },
            onSelectVerseRange: { bookId, chapterNumber, verseStart, verseEnd in
                viewModel.selectVerseRange(
                    bookId: bookId, chapterNumber: chapterNumber, verseStart: verseStart, verseEnd: verseEnd
                )
                onSelect()
            },
            onClose: onClose,
            onPresentBookAnnotations: onPresentBookAnnotations,
            onRequestBookAnnotations: onRequestBookAnnotations,
            onPresentBookNotes: onPresentBookNotes,
            generatingBookIds: generatingBookIds,
            isEmbedded: true,
            isActive: viewModel.tab == .book
        )
    }

    private var segments: some View {
        SuperGlassContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(BibleSelectionSheetViewModel.Tab.allCases, id: \.self) { tab in
                    segment(tab)
                }
            }
            .padding(4)
            .background(theme.backgroundRaised, in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func segment(_ tab: BibleSelectionSheetViewModel.Tab) -> some View {
        let isSelected = viewModel.tab == tab
        return Button {
            withAnimation(BibleSheetMotion(reduceMotion: reduceMotion).animation) { viewModel.tab = tab }
        } label: {
            let label = Text(tab.rawValue)
                .font(typography.font(size: controlSize, weight: .medium))
                .foregroundStyle(isSelected ? theme.ink : theme.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
            if isSelected {
                label.superGlassButton(in: Capsule(), morph: GlassMorphID("selection.tab", in: segmentNamespace))
            } else {
                label
            }
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
