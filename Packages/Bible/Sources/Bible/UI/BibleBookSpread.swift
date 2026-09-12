import Core
import GRDBQuery
import SwiftUI

struct BibleBookSpread: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 22
    @Bindable var workspace: BibleReadingWorkspaceViewModel
    @Query<BibleWorkspaceDecorationsRequest> private var decorations: BibleWorkspaceDecorations
    let pageSize: CGSize
    let onAnnotation: (BibleAnnotationTargetSpec, BibleTranslation) -> Void
    let onNote: (BibleNoteTargetSpec) -> Void
    let onBookmark: (BiblePosition) -> Void

    init(workspace: BibleReadingWorkspaceViewModel, pageSize: CGSize,
         onAnnotation: @escaping (BibleAnnotationTargetSpec, BibleTranslation) -> Void,
         onNote: @escaping (BibleNoteTargetSpec) -> Void,
         onBookmark: @escaping (BiblePosition) -> Void = { _ in }) {
        self.workspace = workspace
        self.pageSize = pageSize
        self.onAnnotation = onAnnotation
        self.onNote = onNote
        self.onBookmark = onBookmark
        _decorations = Query(constant: BibleWorkspaceDecorationsRequest(positions: Array(Set(workspace.visiblePages.map(\.position)))))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            if workspace.startsWithBlankPage {
                boundaryPage("Beginning of the Bible")
            }
            ForEach(workspace.visiblePages) { page in
                if let chapter = workspace.chapters[page.position] {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("\(BibleBookCatalog.standard.book(id: page.position.bookId)?.name ?? page.position.bookId) \(page.position.chapterNumber)")
                                .font(typography.reading(titleSize, relativeTo: nil))
                                .foregroundStyle(theme.inkSoft)
                            Spacer(minLength: 0)
                            Menu {
                                Button("Chapter bookmark", systemImage: "bookmark") { onBookmark(page.position) }
                                Button("Chapter annotations", systemImage: "sparkles") {
                                    onAnnotation(.chapter(bookId: page.position.bookId, chapterNumber: page.position.chapterNumber), page.translation)
                                }
                                Button("Chapter notes", systemImage: "note.text") {
                                    onNote(.chapter(bookId: page.position.bookId, chapterNumber: page.position.chapterNumber))
                                }
                            } label: {
                                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                            }
                            .font(typography.font(.body))
                            .accessibilityLabel("Chapter study actions")
                        }
                        .frame(height: max(44, titleSize * typography.fontScale * 1.5))
                        BibleBookPage(
                            page: page, document: chapter.document,
                            selectedVerses: workspace.reader.selectedVerses(in: chapter.source),
                            highlights: highlights(for: page.position),
                            narratingVerse: workspace.reader.narrationVerseNumber(in: chapter.source),
                            onTapVerse: {
                                workspace.reader.toggleVerse($0, in: chapter.source)
                                workspace.reader.presentActionSheet()
                            },
                            onAnnotation: { onAnnotation($0, page.translation) }, onNote: onNote
                        )
                        .frame(width: pageSize.width, height: pageSize.height)
                    }
                    .frame(width: pageSize.width, alignment: .topLeading)
                }
            }
            if workspace.pageCount == 2, workspace.visiblePages.count == 1, !workspace.startsWithBlankPage {
                boundaryPage(workspace.isAtEnd ? "End of the Bible" : "Next chapter unavailable")
            }
        }
        .tint(theme.inkSoft)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 35).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
            workspace.turn(value.translation.width < 0 ? .next : .previous)
        })
        .accessibilityAction(named: "Previous pages") { workspace.turn(.previous) }
        .accessibilityAction(named: "Next pages") { workspace.turn(.next) }
        .accessibilityScrollAction { edge in
            if edge == .trailing { workspace.turn(.next) }
            if edge == .leading { workspace.turn(.previous) }
        }
        .onChange(of: decorations, initial: true) { _, decorations in
            guard decorations.isLoaded else { return }
            for position in Set(workspace.visiblePages.map(\.position)) {
                workspace.updateDecorations(pageDecorations(for: position), for: position)
            }
        }
    }

    private func boundaryPage(_ title: String) -> some View {
        Text(title)
            .font(typography.reading(titleSize, relativeTo: nil))
            .foregroundStyle(theme.inkFaint)
            .frame(width: pageSize.width, height: pageSize.height)
    }

    private func highlights(for position: BiblePosition) -> [Int: BibleHighlightColor] {
        var result: [Int: BibleHighlightColor] = [:]
        for highlight in decorations.highlights where highlight.bookId == position.bookId && highlight.chapterNumber == position.chapterNumber {
            result[highlight.verseNumber] = highlight.color
        }
        return result
    }

    private func pageDecorations(for position: BiblePosition) -> BiblePageDocument.Decorations {
        var result = BiblePageDocument.Decorations()
        for record in decorations.annotations where record.bookId == position.bookId && record.chapterNumber == position.chapterNumber {
            guard let start = record.verseStart, let end = record.verseEnd else { continue }
            let spec = BibleAnnotationTargetSpec.verseRange(bookId: position.bookId, chapterNumber: position.chapterNumber, verseStart: start, verseEnd: end)
            if !result.annotations[end, default: []].contains(spec) { result.annotations[end, default: []].append(spec) }
        }
        for record in decorations.notes where record.bookId == position.bookId && record.chapterNumber == position.chapterNumber {
            guard let start = record.verseStart, let end = record.verseEnd else { continue }
            let spec = BibleNoteTargetSpec.verseRange(bookId: position.bookId, chapterNumber: position.chapterNumber, verseStart: start, verseEnd: end)
            if !result.notes[end, default: []].contains(spec) { result.notes[end, default: []].append(spec) }
        }
        return result
    }
}
