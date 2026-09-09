import Core
import GRDBQuery
import SwiftUI

/// The book picker: a bottom-aligned sheet listing every book. The expanded
/// book opens an inline 6-column chapter grid; tapping a chapter jumps there
/// and closes the sheet. A search field filters by name and a toggle switches
/// between traditional (Genesis → Revelation, grouped by testament) and
/// alphabetical order.
///
/// Annotation bubbles sit next to each book name. The bubble is `.filled`
/// when the book has at least one annotation row (any target level), and
/// `.empty` otherwise — per spec §5, the book picker is one of the two
/// surfaces that paint empty bubbles to invite generation. The
/// existence-set comes from a reactive `@Query` so writes from other
/// surfaces (chat tool calls, the chapter reader's regenerate path)
/// repaint the picker without intervention.
struct BibleBookSheet: View {
    /// Only layout sizes matter for initial positioning, not live scroll offsets.
    private struct InitialScrollLayout: Equatable {
        let contentSize: CGSize
        let viewportSize: CGSize
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Bindable var viewModel: BibleBookSheetViewModel

    /// Declared once and shared by the nav bar and the presentation so the two
    /// can't drift; an expandable list sheet (`.medium`/`.large`).
    private let sizing = SheetSizing.expandable

    /// The reader's current book / chapter — used to bold the matching row
    /// and mark the matching chapter cell.
    let currentBookId: String
    let currentChapterNumber: Int

    /// Extra bottom padding so the order toggle clears the shell's
    /// minimized chat pill; `0` in standalone (snapshot) contexts.
    let bottomInset: CGFloat
    let onSelectChapter: (_ bookId: String, _ chapterNumber: Int) -> Void
    /// Tap on a resolved verse-range search row — deep-link to those verses,
    /// pre-selected, the same as a `super://bible/` citation tap.
    let onSelectVerseRange: (
        _ bookId: String, _ chapterNumber: Int, _ verseStart: Int, _ verseEnd: Int
    ) -> Void
    let onClose: () -> Void
    /// Tap on a filled bubble — present the annotation sheet for the
    /// `.book(bookId)` target.
    let onPresentBookAnnotations: (_ bookId: String) -> Void
    /// Tap on an empty bubble — start a generation intent for the
    /// `.book(bookId)` target (which the view model routes through its
    /// disclaimer gate).
    let onRequestBookAnnotations: (_ bookId: String) -> Void
    /// Tap on a note glyph (filled or outline) — present the note list sheet
    /// for the `.book(bookId)` target. The user composes from the list's `+`;
    /// an empty book opens to the list's empty state, not straight to the editor.
    let onPresentBookNotes: (_ bookId: String) -> Void
    /// Book ids whose `.book`-target generation is in flight. A book in
    /// this set renders its bubble in the generating state (disabled),
    /// surfacing dispatches triggered from chat or a prior picker visit.
    let generatingBookIds: Set<String>

    /// Books with at least one annotation row at any target level. Used
    /// to switch each bubble between `.filled` and `.empty` per book. An
    /// empty set means *no* books have rows; the entire picker shows
    /// empty bubbles. The default-value-on-failure `[]` matches that —
    /// failing safe to "no annotations" never misleads the user.
    @Query<BookAnnotationsExistenceRequest> private var booksWithAnnotations: Set<String>

    /// Books with at least one *book-level* note (`target == .book`). Switches
    /// each row's note glyph between `.filled` and `.outline`. Scoped to
    /// book-level so the glyph's fill matches what its tap opens
    /// (`NotesForRangeRequest(target: .book, …)`); verse/chapter notes surface
    /// on their own glyphs in the reader. Reactive like the annotation set
    /// above, so a book note written from the reader or chat repaints the
    /// picker. `[]` on failure → all-outline, which reads as "no notes yet"
    /// rather than misleading the user.
    @Query<BookNotesExistenceRequest> private var booksWithNotes: Set<String>

    /// Every assigned bookmark slot, reactive like the annotation/note
    /// existence sets above so a bookmark written from the reader's
    /// assignment sheet (or moved away) repaints the picker's row icons and
    /// chapter-cell badges without intervention. `[]` on failure → no
    /// indicators, which fails safe to "no bookmarks" rather than misleading.
    @Query<AllBookmarksRequest> private var bookmarks: [BibleBookmarkRecord]

    // Font sizes and the chapter cell height are carried as scaled metrics
    // so the picker tracks Dynamic Type — the design's fixed point sizes,
    // scaled relative to the nearest system text style.
    @ScaledMetric(relativeTo: .title3) private var bookNameSize: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var mediumSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var controlSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var countSize: CGFloat = 11
    /// Fixed width for the trailing chapter count, sized for the widest value
    /// (Psalms = 150, three monospaced digits) so single- and double-digit
    /// counts don't shift the glyph cluster's trailing alignment.
    @ScaledMetric(relativeTo: .caption) private var countWidth: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var sectionLabelSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var chapterCellHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var bubbleSize: CGFloat = 20
    /// Row bookmark ribbons sit slightly smaller than the annotation/note
    /// glyphs (≈75% of `bubbleSize`) so they read as a quieter decoration
    /// leading the cluster, not a third tappable control.
    @ScaledMetric(relativeTo: .body) private var rowBookmarkSize: CGFloat = 15
    /// The chapter-cell badge — a small ribbon tucked into the cell's
    /// top-right corner.
    @ScaledMetric(relativeTo: .body) private var cellBookmarkSize: CGFloat = 11
    /// Fixed search-field height so focus, the editing caret, or the
    /// appearing/disappearing clear button can't resize the bar.
    @ScaledMetric(relativeTo: .subheadline) private var searchFieldHeight: CGFloat = 44

    /// Required content + callbacks come first per the AGENTS.md
    /// "Default parameter values" rule; the lone `bottomInset` default
    /// stays trailing.
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
        // Detents + drag indicator + background, derived from `sizing`.
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
        // Fixed height (not vertical padding) so the bar can't resize when the
        // field gains focus / the caret appears or the clear button shows/hides —
        // its old height was derived from the tallest child's intrinsic metrics.
        .frame(height: searchFieldHeight)
        // Interactive glass — the field still owns its own focus tap; the glass
        // just adds the press response the rest of the sheet's controls have.
        .superGlassButton(in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var bookList: some View {
        let groups = viewModel.groups
        // Non-lazy on purpose: the picker scroll-anchors to either a book
        // row or a specific chapter cell when it first appears, and
        // `ScrollViewProxy.scrollTo` only resolves ids that are already
        // laid out. The fan-out is bounded — 66 books + at most one
        // expanded book's chapter grid (150 in Psalms is the worst case)
        // — so eager layout is cheap. Lazy variants made `scrollTo`
        // silently fail for any target below the initial viewport.
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let result = viewModel.deepLinkResult {
                        // The query named a concrete chapter / verse — show a
                        // single tappable jump row in place of the book list.
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
            .onScrollGeometryChange(for: InitialScrollLayout.self) { geometry in
                InitialScrollLayout(contentSize: geometry.contentSize, viewportSize: geometry.containerSize)
            } action: { _, layout in
                viewModel.updateInitialScrollLayout(
                    contentSize: layout.contentSize,
                    viewportSize: layout.viewportSize
                )
            }
            .onChange(of: viewModel.canResolveInitialScroll, initial: true) { _, _ in
                // onAppear can precede target registration on iOS 27. The
                // target's own geometry and the scroll layout must both exist
                // before consuming this sole, non-animated positioning request.
                guard let anchor = viewModel.consumeInitialScrollAnchor() else { return }
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

    /// Stable identifier the book name row registers with `ScrollViewReader`,
    /// used to scroll a book to the top of the picker viewport.
    static func bookRowID(_ bookId: String) -> String { "book-\(bookId)" }

    /// Stable identifier each chapter cell registers with `ScrollViewReader`,
    /// used to anchor the current chapter cell into view for long books.
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

    /// The single jump row shown when the search query resolved to a concrete
    /// chapter or verse range. Tapping it deep-links and closes the sheet.
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
        let scrollAnchor = BibleBookSheetScrollAnchor.bookRow(bookId: book.id)
        let isInitialScrollTarget = viewModel.initialScrollAnchor == scrollAnchor

        VStack(alignment: .leading, spacing: 0) {
            // Row layout: a tappable name area (expansion toggle) flush
            // left, an annotation bubble carved out as its own tap target,
            // and the chapter count flush right. Splitting the bubble out
            // of the expansion button keeps the two intents independent —
            // tapping the bubble never expands the book and vice versa.
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

                // The glyphs cluster tightly together; their frames hug
                // their ink (see AnnotationBubble / NoteGlyph), so this spacing
                // is the real visible gap between them. The bookmark ribbons
                // lead the cluster (left of the annotation bubble) and are
                // emitted only when the book has bookmarks — an absent branch
                // reserves no spacing, so unbookmarked rows stay pixel-identical.
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
        .onGeometryChange(for: CGSize?.self) { geometry in
            isInitialScrollTarget ? geometry.size : nil
        } action: { size in
            if let size { viewModel.updateInitialScrollTarget(scrollAnchor, size: size) }
        }
    }

    /// The leading run of filled ribbon glyphs on a book row — one per
    /// bookmark the book carries, in chapter order. Decorative: collapsed
    /// into one combined VoiceOver element (the reader is where a bookmark
    /// is edited), so the row's tap targets stay the name, the bubble, and
    /// the note glyph. Emits nothing for a book with no bookmarks.
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

    /// This book's bookmarks in chapter order, each paired with its colour;
    /// rows whose persisted `colorId` is unknown (a forward-compat slot)
    /// fail safe by dropping out rather than rendering a blank glyph.
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

    /// The colour marking a specific chapter cell, or `nil` when unbookmarked.
    private func bookmarkColor(forBook bookId: String, chapter: Int) -> BibleBookmarkColor? {
        bookmarks.first { $0.bookId == bookId && $0.chapterNumber == chapter }?.color
    }

    /// Combined VoiceOver label for a book row's bookmark cluster, e.g.
    /// `"Bookmarks: Clay chapter 3, Gold chapter 8"`. A `for`-loop, not
    /// `map`, to stay clear of the `swift test`-on-macOS predicate-closure
    /// trap this package documents.
    static func bookBookmarksLabel(_ marks: [(color: BibleBookmarkColor, chapterNumber: Int)]) -> String {
        var parts: [String] = []
        for mark in marks {
            parts.append("\(mark.color.displayName) chapter \(mark.chapterNumber)")
        }
        return "Bookmarks: " + parts.joined(separator: ", ")
    }

    /// VoiceOver label for a chapter cell, appending the ribbon colour when
    /// the chapter is bookmarked so the badge isn't a silent visual-only cue.
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

    /// VoiceOver label for a book's annotation bubble, keyed to its state.
    static func bookBubbleLabel(for state: AnnotationBubble.BubbleState) -> String {
        switch state {
        case .filled: return "View annotations for this book"
        case .empty: return "Generate annotations for this book"
        case .generating: return "Generating annotations for this book"
        }
    }

    /// The book row's note glyph — tapping always opens the book-level note
    /// list (the empty state prompts the user to compose from the `+`). Renders
    /// filled when the book carries ≥1 *book-level* note, outline when none yet.
    /// Carved out as its own tap target so it never expands the book or fires
    /// the annotation bubble.
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

    /// VoiceOver label for a book's note glyph, keyed to whether it has notes.
    static func bookNoteGlyphLabel(hasNotes: Bool) -> String {
        hasNotes ? "View notes for this book" : "Open notes for this book"
    }

    private func chapterGrid(for book: BibleBookSummary) -> some View {
        // Non-lazy on purpose: a `LazyVGrid` only materializes the cells in
        // its viewport, which makes `ScrollViewProxy.scrollTo` for an
        // off-screen chapter cell (e.g. Psalms 119) silently no-op. With a
        // bounded fan-out — Psalms's 150 chapters is the worst case —
        // eager layout is cheap and lets the picker scroll-anchor to any
        // chapter cell as soon as the book's row is laid out.
        let columns = BibleBookSheetViewModel.chapterGridColumns
        let rowCount = (book.chapterCount + columns - 1) / columns
        // One shared glass sampling region for the whole grid: without it each cell's
        // interactive glass samples independently and casts its own elevation shadow,
        // producing the fragmented "strange shadow behind each component" artifacts.
        // `spacing: 0` sets the merge threshold to 0, so cells share the sampling
        // region but never merge; the 6pt VStack/HStack gap keeps them separated.
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
        let scrollAnchor = BibleBookSheetScrollAnchor.chapterCell(bookId: book.id, chapterNumber: number)
        let isInitialScrollTarget = viewModel.initialScrollAnchor == scrollAnchor
        Button {
            onSelectChapter(book.id, number)
        } label: {
            cellBody(number: number, isCurrent: isCurrent)
                // A small ribbon tucked into the corner marks a bookmarked
                // chapter; the `nil` branch adds nothing, so unbookmarked
                // grids stay pixel-identical to the existing baselines.
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
        .onGeometryChange(for: CGSize?.self) { geometry in
            isInitialScrollTarget ? geometry.size : nil
        } action: { size in
            if let size { viewModel.updateInitialScrollTarget(scrollAnchor, size: size) }
        }
    }

    /// The cell's fill + number, split out so the bookmark badge overlay can
    /// layer over either the selected (solid `ink`) or unselected (glass)
    /// background uniformly.
    @ViewBuilder
    private func cellBody(number: Int, isCurrent: Bool) -> some View {
        if isCurrent {
            // The current chapter keeps a solid `ink` fill so it reads as
            // selected against the interactive glass of the other cells.
            chapterLabel(number, isCurrent: true)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.ink))
        } else {
            chapterLabel(number, isCurrent: false)
                .superGlassButton(in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// The chapter number sized to fill a grid cell; the caller layers the
    /// background (solid `ink` when selected, interactive glass otherwise).
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
        // Frosted glass track for the segmented toggle, matching the nav-bar
        // pills; the active segment keeps its own raised inner capsule so it
        // still reads as selected against the surface.
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
