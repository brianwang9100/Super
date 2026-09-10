import Core
import SwiftUI

/// A native selector that stages a passage and translation together before reading.
struct BibleSelectionSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: BibleSelectionSheetViewModel
    @ScaledMetric(relativeTo: .subheadline) private var controlSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var readSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var subtitleSize: CGFloat = 11
    @Namespace private var segmentNamespace

    let onRead: () -> Void
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
                        onSelect: { viewModel.translation = $0 }, onClose: onClose,
                        isEmbedded: true
                    )
                }
                .opacity(viewModel.tab == .translation ? 1 : 0)
                .allowsHitTesting(viewModel.tab == .translation)
                .accessibilityHidden(viewModel.tab != .translation)
            }
            .frame(maxHeight: .infinity)
            readButton
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
            onSelectChapter: viewModel.selectChapter,
            onSelectVerseRange: viewModel.selectVerseRange,
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
            .superGlassSurface(in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func segment(_ tab: BibleSelectionSheetViewModel.Tab) -> some View {
        let isSelected = viewModel.tab == tab
        return Button {
            withAnimation(BibleSheetMotion(reduceMotion: reduceMotion).animation) { viewModel.tab = tab }
        } label: {
            Text(tab.rawValue)
                .font(typography.font(size: controlSize, weight: .medium))
                .foregroundStyle(isSelected ? theme.ink : theme.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.clear)
                            .superGlassButton(in: Capsule(), morph: GlassMorphID("selection.tab", in: segmentNamespace))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var readButton: some View {
        Button(action: onRead) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Read \(viewModel.citation)")
                        .font(typography.font(size: readSize, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Text("\(viewModel.translation.name) · \(viewModel.translation.rawValue)")
                        .font(typography.font(size: subtitleSize))
                        .foregroundStyle(theme.inkSoft)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(typography.font(size: readSize, weight: .medium))
                    .foregroundStyle(theme.ink)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .superGlassButton(in: RoundedRectangle(cornerRadius: 26))
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("Read \(viewModel.citation), \(viewModel.translation.name)")
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}
