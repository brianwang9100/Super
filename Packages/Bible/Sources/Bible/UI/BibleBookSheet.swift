import Core
import SwiftUI

/// The book picker: a bottom-aligned sheet listing every book. The expanded
/// book opens an inline 6-column chapter grid; tapping a chapter jumps there
/// and closes the sheet. A search field filters by name and a toggle switches
/// between traditional (Genesis → Revelation, grouped by testament) and
/// alphabetical order.
struct BibleBookSheet: View {
    @Environment(\.superTheme) private var theme
    @Bindable var viewModel: BibleBookSheetViewModel

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
    let onClose: () -> Void

    // Font sizes and the chapter cell height are carried as scaled metrics
    // so the picker tracks Dynamic Type — the design's fixed point sizes,
    // scaled relative to the nearest system text style.
    @ScaledMetric(relativeTo: .title3) private var bookNameSize: CGFloat = 18
    @ScaledMetric(relativeTo: .headline) private var headerSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var mediumSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var controlSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var countSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var sectionLabelSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var chapterCellHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            searchField
            bookList
            orderToggle
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(theme.background)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(theme.inkFaint)
            .frame(width: 36, height: 4)
            .opacity(0.6)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    private var header: some View {
        ZStack {
            Text("Books")
                .font(.system(size: headerSize, weight: .semibold))
                .foregroundStyle(theme.ink)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: controlSize, weight: .semibold))
                        .foregroundStyle(theme.inkSoft)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(theme.backgroundSunken))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: controlSize, weight: .medium))
                .foregroundStyle(theme.inkFaint)

            TextField("Search books", text: $viewModel.query)
                .font(.system(size: mediumSize))
                .foregroundStyle(theme.ink)
                .autocorrectionDisabled()

            if !viewModel.query.isEmpty {
                Button { viewModel.clearQuery() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: mediumSize))
                        .foregroundStyle(theme.inkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.backgroundSunken))
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
                    if groups.isEmpty {
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
            .font(.system(size: sectionLabelSize, weight: .medium, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(theme.inkFaint)
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private var emptyState: some View {
        Text("No books match \u{201C}\(viewModel.query)\u{201D}.")
            .font(.system(size: controlSize))
            .foregroundStyle(theme.inkFaint)
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
    }

    @ViewBuilder
    private func bookRow(_ book: BibleBookSummary) -> some View {
        let isExpanded = viewModel.expandedBookId == book.id
        let isCurrent = book.id == currentBookId

        VStack(alignment: .leading, spacing: 0) {
            Button {
                viewModel.toggleExpansion(bookId: book.id)
            } label: {
                HStack {
                    Text(book.name)
                        .font(.system(size: bookNameSize, weight: isCurrent ? .medium : .regular))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Text("\(book.chapterCount)")
                        .font(.system(size: countSize, design: .monospaced))
                        .foregroundStyle(theme.inkFaint)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                chapterGrid(for: book)
            }
        }
        .id(Self.bookRowID(book.id))
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
        return VStack(spacing: 6) {
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
            Text("\(number)")
                .font(.system(size: mediumSize, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? theme.backgroundRaised : theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: chapterCellHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isCurrent ? theme.ink : theme.backgroundRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.borderFaint, lineWidth: isCurrent ? 0 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.name) chapter \(number)")
        .id(Self.chapterCellID(bookId: book.id, chapterNumber: number))
    }

    private var orderToggle: some View {
        HStack(spacing: 0) {
            toggleSegment("Traditional", order: .traditional)
            toggleSegment("Alphabetical", order: .alphabetical)
        }
        .padding(4)
        .background(Capsule().fill(theme.backgroundSunken))
        .padding(.top, 8)
        .padding(.bottom, 22 + bottomInset)
    }

    private func toggleSegment(_ title: String, order: BibleBookOrder) -> some View {
        let isActive = viewModel.order == order
        return Button {
            viewModel.order = order
        } label: {
            Text(title)
                .font(.system(size: controlSize, weight: isActive ? .medium : .regular))
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
        bottomInset: 0,
        onSelectChapter: { _, _ in },
        onClose: {}
    )
    .superTheme(.make(.light))
}
