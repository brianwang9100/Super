import Core
import GRDBQuery
import SwiftUI

struct BibleBookSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Bindable var viewModel: BibleBookSheetViewModel

    private let sizing = SheetSizing.expandable

    let currentBookId: String
    let currentChapterNumber: Int

    // Anchor once per appearance; search/order layout changes must not pull the user back.
    @State private var didAutoScroll = false
    /// Reserve for the minimized chat pill; zero in standalone contexts.
    let bottomInset: CGFloat
    let onSelectChapter: (_ bookId: String, _ chapterNumber: Int) -> Void
    /// Opens and preselects the resolved range, like a Bible deep link.
    let onSelectVerseRange: (
        _ bookId: String, _ chapterNumber: Int, _ verseStart: Int, _ verseEnd: Int
    ) -> Void
    let onClose: () -> Void
    let onPresentBookAnnotations: (_ bookId: String) -> Void
    let onRequestBookAnnotations: (_ bookId: String) -> Void
    /// Opens the book-level list, including its empty state; it does not auto-compose.
    let onPresentBookNotes: (_ bookId: String) -> Void
    let generatingBookIds: Set<String>

    @Query<BookAnnotationsExistenceRequest> private var booksWithAnnotations: Set<String>

    @Query<BookNotesExistenceRequest> private var booksWithNotes: Set<String>

    @Query<AllBookmarksRequest> private var bookmarks: [BibleBookmarkRecord]

    @ScaledMetric(relativeTo: .title3) private var bookNameSize: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var mediumSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var controlSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var countSize: CGFloat = 11
    // Reserve three monospaced digits so chapter counts do not shift the glyph cluster.
    @ScaledMetric(relativeTo: .caption) private var countWidth: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var sectionLabelSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var chapterCellHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var bubbleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var rowBookmarkSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var cellBookmarkSize: CGFloat = 11
    @ScaledMetric(relativeTo: .subheadline) private var searchFieldHeight: CGFloat = 44

    init(
        viewModel: BibleBookSheetViewModel,
        currentBookId: String,
        currentChapterNumber: Int,
        onSelectChapter: @escaping (_ bookId: String, _ chapterNumber: Int) -> Void,
        onSelectVerseRange: @escaping (
            _ bookId: String, _ chapterNumber: Int, _ verseStart: Int, _ verseEnd: Int
        ) -> Void,
        onClose: @escaping () -> Void,
        onPresentBookAnnotations: @escaping (_ bookId: String) -> Void,
        onRequestBookAnnotations: @escaping (_ bookId: String) -> Void,
        onPresentBookNotes: @escaping (_ bookId: String) -> Void,
        generatingBookIds: Set<String> = [],
        bottomInset: CGFloat = 0
    ) {
        self.viewModel = viewModel
        self.currentBookId = currentBookId
        self.currentChapterNumber = currentChapterNumber
        self.onSelectChapter = onSelectChapter
        self.onSelectVerseRange = onSelectVerseRange
        self.onClose = onClose
        self.onPresentBookAnnotations = onPresentBookAnnotations
        self.onRequestBookAnnotations = onRequestBookAnnotations
        self.onPresentBookNotes = onPresentBookNotes
        self.generatingBookIds = generatingBookIds
        self.bottomInset = bottomInset
        self._booksWithAnnotations = Query(constant: BookAnnotationsExistenceRequest())
        self._booksWithNotes = Query(constant: BookNotesExistenceRequest())
        self._bookmarks = Query(constant: AllBookmarksRequest())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            bookList
            orderToggle
        }
        .sheetPresentation(sizing)
    }

    private var header: some View {
        SheetNavBar(title: "Books", sizing: sizing, onClose: onClose)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(typography.font(size: controlSize, weight: .medium))
                .foregroundStyle(theme.inkFaint)

            TextField("Search — e.g. 1 Peter 2:5", text: $viewModel.query)
                .font(typography.font(size: mediumSize))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .autocorrectionDisabled()

            if !viewModel.query.isEmpty {
                Button { viewModel.clearQuery() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(typography.font(size: mediumSize))
                        .foregroundStyle(theme.inkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        // Fix height so focus, caret, and clear-button changes cannot resize the bar.
        .frame(height: searchFieldHeight)
        .superGlassButton(in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var bookList: some View {
        let groups = viewModel.groups
        // scrollTo requires laid-out IDs. Eager layout is bounded by 66 books plus one
        // chapter grid; lazy layout cannot anchor below the initial viewport.
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let result = viewModel.deepLinkResult {
                        deepLinkRow(result)
                    } else if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups) { group in
                            if let title = group.title {
                                sectionHeader(title)
                            }
                            ForEach(group.books) { book in
                                bookRow(book)
                            }
                        }
                    }
                }
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard !didAutoScroll, let anchor = viewModel.initialScrollAnchor else { return }
                didAutoScroll = true
                switch anchor {
                case .bookRow(let bookId):
                    proxy.scrollTo(Self.bookRowID(bookId), anchor: .top)
                case .chapterCell(let bookId, let chapterNumber):
                    proxy.scrollTo(
                        Self.chapterCellID(bookId: bookId, chapterNumber: chapterNumber),
                        anchor: .center
                    )
                }
            }
        }
    }

    static func bookRowID(_ bookId: String) -> String { "book-\(bookId)" }

    static func chapterCellID(bookId: String, chapterNumber: Int) -> String {
        "chapter-\(bookId)-\(chapterNumber)"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(typography.font(size: sectionLabelSize, weight: .medium, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(theme.inkFaint)
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private var emptyState: some View {
        Text("No books match \u{201C}\(viewModel.bookNameFilter)\u{201D}.")
            .font(typography.font(size: controlSize))
            .foregroundStyle(theme.inkFaint)
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
    }

    private func deepLinkRow(_ result: BibleSearchResult) -> some View {
        Button {
            switch result {
            case let .chapter(bookId, _, chapterNumber):
                onSelectChapter(bookId, chapterNumber)
            case let .verseRange(bookId, _, chapterNumber, verseStart, verseEnd):
                onSelectVerseRange(bookId, chapterNumber, verseStart, verseEnd)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.displayLabel)
                        .font(typography.font(size: bookNameSize, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Text(result.subtitle)
                        .font(typography.font(size: countSize))
                        .foregroundStyle(theme.inkFaint)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(typography.font(size: controlSize, weight: .semibold))
                    .foregroundStyle(theme.inkFaint)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Go to \(result.displayLabel)")
    }

    @ViewBuilder
    private func bookRow(_ book: BibleBookSummary) -> some View {
        let isExpanded = viewModel.isBookExpanded(book.id)
        let isCurrent = book.id == currentBookId
        let hasAnnotations = booksWithAnnotations.contains(book.id)
        let hasNotes = booksWithNotes.contains(book.id)

        VStack(alignment: .leading, spacing: 0) {
            // Separate tap targets prevent annotation actions from toggling expansion.
            HStack(spacing: 8) {
                Button {
                    viewModel.toggleExpansion(bookId: book.id)
                } label: {
                    HStack(spacing: 8) {
                        Text(book.name)
                            .font(typography.font(size: bookNameSize, weight: isCurrent ? .medium : .regular))
                            .foregroundStyle(theme.ink)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 7) {
                    bookmarkRibbons(for: book.id)
                    annotationBubble(for: book.id, hasAnnotations: hasAnnotations)
                    noteGlyph(for: book.id, hasNotes: hasNotes)
                }

                Text("\(book.chapterCount)")
                    .font(typography.font(size: countSize, design: .monospaced))
                    .foregroundStyle(theme.inkFaint)
                    .frame(width: countWidth, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)

            if isExpanded {
                chapterGrid(for: book)
            }
        }
        .id(Self.bookRowID(book.id))
    }

    /// Decorative ribbons combine into one VoiceOver element; they add no tap targets.
    @ViewBuilder
    private func bookmarkRibbons(for bookId: String) -> some View {
        let marks = bookmarks(forBook: bookId)
        if !marks.isEmpty {
            HStack(spacing: 3) {
                ForEach(marks, id: \.color) { mark in
                    BookmarkGlyph(state: .filled(mark.color), size: rowBookmarkSize)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.bookBookmarksLabel(marks))
        }
    }

    private func bookmarks(forBook bookId: String) -> [(color: BibleBookmarkColor, chapterNumber: Int)] {
        var marks: [(color: BibleBookmarkColor, chapterNumber: Int)] = []
        for record in bookmarks where record.bookId == bookId {
            if let color = record.color {
                marks.append((color: color, chapterNumber: record.chapterNumber))
            }
        }
        marks.sort { $0.chapterNumber < $1.chapterNumber }
        return marks
    }

    private func bookmarkColor(forBook bookId: String, chapter: Int) -> BibleBookmarkColor? {
        bookmarks.first { $0.bookId == bookId && $0.chapterNumber == chapter }?.color
    }

    // A loop avoids the macOS predicate-closure inference issue in Swift tests.
    static func bookBookmarksLabel(_ marks: [(color: BibleBookmarkColor, chapterNumber: Int)]) -> String {
        var parts: [String] = []
        for mark in marks {
            parts.append("\(mark.color.displayName) chapter \(mark.chapterNumber)")
        }
        return "Bookmarks: " + parts.joined(separator: ", ")
    }

    static func chapterCellLabel(bookName: String, number: Int, bookmark: BibleBookmarkColor?) -> String {
        let base = "\(bookName) chapter \(number)"
        guard let bookmark else { return base }
        return "\(base), bookmarked \(bookmark.displayName)"
    }

    private func annotationBubble(for bookId: String, hasAnnotations: Bool) -> some View {
        let state = AnnotationBubble.state(
            hasAnnotation: hasAnnotations,
            isGenerating: generatingBookIds.contains(bookId)
        )
        return Button {
            switch state {
            case .filled: onPresentBookAnnotations(bookId)
            case .empty: onRequestBookAnnotations(bookId)
            case .generating: break
            }
        } label: {
            AnnotationBubble(state: state, size: bubbleSize)
                // Height-only frame: a fixed width re-introduces side-bearing and widens the icon→icon gap.
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state == .generating)
        .accessibilityLabel(Self.bookBubbleLabel(for: state))
    }

    static func bookBubbleLabel(for state: AnnotationBubble.BubbleState) -> String {
        switch state {
        case .filled: return "View annotations for this book"
        case .empty: return "Generate annotations for this book"
        case .generating: return "Generating annotations for this book"
        }
    }

    private func noteGlyph(for bookId: String, hasNotes: Bool) -> some View {
        let glyphState: NoteGlyph.GlyphState = hasNotes ? .filled : .outline
        return Button {
            onPresentBookNotes(bookId)
        } label: {
            NoteGlyph(state: glyphState, size: bubbleSize)
                // Height-only frame: a fixed width re-introduces side-bearing and widens the icon→icon gap.
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.bookNoteGlyphLabel(hasNotes: hasNotes))
    }

    static func bookNoteGlyphLabel(hasNotes: Bool) -> String {
        hasNotes ? "View notes for this book" : "Open notes for this book"
    }

    private func chapterGrid(for book: BibleBookSummary) -> some View {
        // Keep cells eager too: lazy off-screen IDs cannot resolve scrollTo. Psalms bounds this at 150 cells.
        let columns = BibleBookSheetViewModel.chapterGridColumns
        let rowCount = (book.chapterCount + columns - 1) / columns
        // Share glass sampling to avoid per-cell elevation artifacts; zero merge threshold
        // and explicit gaps keep the cells visually separate.
        return SuperGlassContainer(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(0..<rowCount, id: \.self) { rowIndex in
                    HStack(spacing: 6) {
                        ForEach(0..<columns, id: \.self) { column in
                            let number = rowIndex * columns + column + 1
                            if number <= book.chapterCount {
                                chapterCell(for: book, number: number)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: chapterCellHeight)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func chapterCell(for book: BibleBookSummary, number: Int) -> some View {
        let isCurrent = book.id == currentBookId && number == currentChapterNumber
        let bookmark = bookmarkColor(forBook: book.id, chapter: number)
        Button {
            onSelectChapter(book.id, number)
        } label: {
            cellBody(number: number, isCurrent: isCurrent)
                .overlay(alignment: .topTrailing) {
                    if let bookmark {
                        BookmarkGlyph(state: .filled(bookmark), size: cellBookmarkSize)
                            .padding(.top, 3)
                            .padding(.trailing, 3)
                    }
                }
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel(Self.chapterCellLabel(bookName: book.name, number: number, bookmark: bookmark))
        .id(Self.chapterCellID(bookId: book.id, chapterNumber: number))
    }

    @ViewBuilder
    private func cellBody(number: Int, isCurrent: Bool) -> some View {
        if isCurrent {
            chapterLabel(number, isCurrent: true)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.ink))
        } else {
            chapterLabel(number, isCurrent: false)
                .superGlassButton(in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func chapterLabel(_ number: Int, isCurrent: Bool) -> some View {
        Text("\(number)")
            .font(typography.font(size: mediumSize, weight: isCurrent ? .semibold : .medium))
            .foregroundStyle(isCurrent ? theme.backgroundRaised : theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: chapterCellHeight)
    }

    private var orderToggle: some View {
        HStack(spacing: 0) {
            toggleSegment("Traditional", order: .traditional)
            toggleSegment("Alphabetical", order: .alphabetical)
        }
        .padding(4)
        .superGlassSurface(in: Capsule())
        .padding(.top, 8)
        .padding(.bottom, 22 + bottomInset)
    }

    private func toggleSegment(_ title: String, order: BibleBookOrder) -> some View {
        let isActive = viewModel.order == order
        return Button {
            viewModel.order = order
        } label: {
            Text(title)
                .font(typography.font(size: controlSize, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? theme.ink : theme.inkSoft)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .background(Capsule().fill(isActive ? theme.backgroundRaised : .clear))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    BibleBookSheet(
        viewModel: BibleBookSheetViewModel(
            currentPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        ),
        currentBookId: "1PE",
        currentChapterNumber: 2,
        onSelectChapter: { _, _ in },
        onSelectVerseRange: { _, _, _, _ in },
        onClose: {},
        onPresentBookAnnotations: { _ in },
        onRequestBookAnnotations: { _ in },
        onPresentBookNotes: { _ in }
    )
    .superTheme(.make(.vellumLight))
}
