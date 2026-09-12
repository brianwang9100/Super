import Core
import GRDBQuery
import SwiftUI

struct BibleTranslationComparison: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 24
    @Bindable var workspace: BibleReadingWorkspaceViewModel
    @Query<BibleWorkspaceDecorationsRequest> private var decorations: BibleWorkspaceDecorations
    @State private var isUserScrolling = false
    @State private var visibleVerses: Set<Int> = []
    let stacked: Bool
    let topInset: CGFloat
    var onAnnotation: (BibleAnnotationTargetSpec, BibleTranslation) -> Void
    var onNote: (BibleNoteTargetSpec) -> Void

    init(workspace: BibleReadingWorkspaceViewModel, stacked: Bool, topInset: CGFloat,
         onAnnotation: @escaping (BibleAnnotationTargetSpec, BibleTranslation) -> Void = { _, _ in },
         onNote: @escaping (BibleNoteTargetSpec) -> Void = { _ in }) {
        self.workspace = workspace
        self.stacked = stacked
        self.topInset = topInset
        self.onAnnotation = onAnnotation
        self.onNote = onNote
        _decorations = Query(constant: BibleWorkspaceDecorationsRequest(positions: [workspace.reader.position]))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Section {
                        if let primary = workspace.reader.primarySource, let secondary = workspace.comparisonSource {
                            let comparison = BibleComparisonAssembler.assemble(primary: primary.chapter, secondary: secondary.chapter)
                            ForEach(comparison.rows) { row in
                                rowContent(row, primary: primary, secondary: secondary)
                                    .padding(.vertical, 14)
                                    .overlay(alignment: .bottom) { theme.ink.opacity(0.10).frame(height: 1) }
                                    .id(row.verseNumber)
                                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                                        if visible { visibleVerses.insert(row.verseNumber) } else { visibleVerses.remove(row.verseNumber) }
                                        if isUserScrolling { workspace.rememberVisibleVerses(visibleVerses) }
                                    }
                            }
                            rowLayout {
                                headings(comparison.primaryTrailingHeadings)
                                headings(comparison.secondaryTrailingHeadings)
                            }
                        } else {
                            VStack(spacing: 12) {
                                Text(workspace.comparisonError ?? "Chapter unavailable")
                                Button("Retry") { workspace.refreshComparison() }
                                    .frame(minHeight: 44)
                            }
                            .font(typography.font(.body))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        }
                        Color.clear.frame(height: 160)
                    }
                }
                .padding(.horizontal, 24)
            }
            .safeAreaInset(edge: .top, spacing: 0) { translationHeader.padding(.horizontal, 24) }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
                if isUserScrolling { workspace.rememberVisibleVerses(visibleVerses) }
            }
            .padding(.top, topInset)
            .task(id: workspace.reader.pendingScrollVerse) {
                guard let verse = workspace.reader.pendingScrollVerse else { return }
                proxy.scrollTo(verse, anchor: .top)
                _ = workspace.reader.consumePendingScrollVerse()
            }
            .onChange(of: workspace.reader.narration.currentVerseNumber) { _, verse in
                guard let verse, workspace.reader.narrationSource?.position == workspace.reader.position,
                      let translation = workspace.reader.narrationSource?.translation,
                      translation == workspace.reader.translation || translation == workspace.secondaryTranslation,
                      workspace.reader.selectedVerses.isEmpty else { return }
                proxy.scrollTo(verse, anchor: .center)
            }
            .onChange(of: workspace.reader.isActionSheetPresented) { old, new in
                if !old, new, let verse = workspace.reader.selectedVerses.min() {
                    proxy.scrollTo(verse, anchor: .center)
                }
            }
        }
    }

    private var translationHeader: some View {
        HStack(spacing: 24) {
            Text(workspace.reader.translation.rawValue)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(BibleTranslation.allCases.filter { $0 != workspace.reader.translation }) { translation in
                    Button(translation.name) { workspace.selectSecondaryTranslation(translation) }
                }
            } label: {
                Label(workspace.secondaryTranslation.rawValue, systemImage: "chevron.down")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("Comparison translation: \(workspace.secondaryTranslation.name)")
        }
        .font(typography.font(.headline))
        .foregroundStyle(theme.inkSoft)
        .padding(.vertical, 8)
        .background(theme.background)
    }

    @ViewBuilder private func rowContent(_ row: BibleComparisonRow, primary: BibleReadingSource, secondary: BibleReadingSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !stacked, !(row.primary?.headings.isEmpty ?? true) || !(row.secondary?.headings.isEmpty ?? true) {
                HStack(alignment: .top, spacing: 24) {
                    headings(row.primary?.headings ?? [])
                    headings(row.secondary?.headings ?? [])
                }
            }
            rowLayout {
                cell(row.primary, verse: row.verseNumber, source: primary)
                cell(row.secondary, verse: row.verseNumber, source: secondary)
            }
        }
    }

    private var rowLayout: AnyLayout {
        stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }

    private func cell(_ cell: BibleComparisonRow.Cell?, verse: Int, source: BibleReadingSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if stacked {
                Text(source.translation.rawValue).font(typography.font(.caption)).foregroundStyle(theme.inkFaint)
            }
            if let cell {
                if stacked { headings(cell.headings) }
                Text("\(verse)  " + cell.text)
                    .font(typography.reading(bodySize, relativeTo: nil))
                    .lineSpacing(bodySize * typography.fontScale * 4 / 17)
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlightColor(verse))
                    .background(workspace.reader.selectedVerses(in: source).contains(verse) ? theme.ink.opacity(0.1) : .clear)
                    .overlay(alignment: .bottom) {
                        if workspace.reader.narrationVerseNumber(in: source) == verse { theme.ink.frame(height: 1) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectVerse(verse, source: source) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(source.translation.rawValue). " + BibleVerseAnnouncement.label(verseNumber: verse, verseText: cell.text))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default) { selectVerse(verse, source: source) }
                studyGlyphs(verse: verse, source: source)
            } else {
                Text("Verse \(verse) is not present in \(source.translation.rawValue)")
                    .font(typography.font(.callout)).foregroundStyle(theme.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func headings(_ titles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                Text(title).font(typography.reading(bodySize, relativeTo: nil, weight: .semibold)).foregroundStyle(theme.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectVerse(_ verse: Int, source: BibleReadingSource) {
        workspace.reader.toggleVerse(verse, in: source)
        workspace.reader.presentActionSheet()
    }

    private func studyGlyphs(verse: Int, source: BibleReadingSource) -> some View {
        let annotations = decorations.annotations.filter { $0.verseEnd == verse }
        let notes = decorations.notes.filter { $0.verseEnd == verse }
        return HStack(spacing: 12) {
            ForEach(annotations) { record in
                if let start = record.verseStart {
                    let spec = BibleAnnotationTargetSpec.verseRange(bookId: source.position.bookId,
                        chapterNumber: source.position.chapterNumber, verseStart: start, verseEnd: verse)
                    Button { onAnnotation(spec, source.translation) } label: { AnnotationBubble(state: .filled, size: 20).frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.plain).accessibilityLabel(BibleParagraphBlock.trailingBubbleLabel(for: spec))
                }
            }
            ForEach(notes) { record in
                if let start = record.verseStart {
                    let spec = BibleNoteTargetSpec.verseRange(bookId: source.position.bookId,
                        chapterNumber: source.position.chapterNumber, verseStart: start, verseEnd: verse)
                    Button { onNote(spec) } label: { NoteGlyph(state: .filled, size: 20).frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.plain).accessibilityLabel(BibleParagraphBlock.trailingNoteGlyphLabel(for: spec))
                }
            }
        }
    }

    private func highlightColor(_ verse: Int) -> Color {
        decorations.highlights.first { $0.verseNumber == verse }?.color?.verseTint(forDarkPage: theme.isDark).color ?? .clear
    }
}
