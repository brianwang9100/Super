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

    /// Single-fire latch so the picker anchors to the current position
    /// exactly once per appearance. Without it, subsequent layout passes
    /// triggered by search/order toggles would yank the scroll back to the
    /// current position after the reader has moved it.
    @State private var didAutoScroll = false
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
        // Taller bar (was 9) — a roomier, more tappable search field.
        .padding(.vertical, 13)
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

                // The two glyphs cluster tightly together; their frames hug
                // their ink (see AnnotationBubble / NoteGlyph), so this spacing
                // is the real visible gap between them.
                HStack(spacing: 7) {
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
        Button {
            onSelectChapter(book.id, number)
        } label: {
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
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.name) chapter \(number)")
        .id(Self.chapterCellID(bookId: book.id, chapterNumber: number))
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
