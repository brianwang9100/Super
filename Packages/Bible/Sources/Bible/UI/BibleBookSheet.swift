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
    let onSelectChapter: (_ bookId: String, _ chapterNumber: Int) -> Void
    let onClose: () -> Void

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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.inkFaint)

            TextField("Search books", text: $viewModel.query)
                .font(.system(size: 14))
                .foregroundStyle(theme.ink)
                .autocorrectionDisabled()

            if !viewModel.query.isEmpty {
                Button { viewModel.clearQuery() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
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
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(theme.inkFaint)
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private var emptyState: some View {
        Text("No books match \u{201C}\(viewModel.query)\u{201D}.")
            .font(.system(size: 13))
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
                        .font(.system(size: 18, weight: isCurrent ? .medium : .regular))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Text("\(book.chapterCount)")
                        .font(.system(size: 11, design: .monospaced))
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
    }

    private func chapterGrid(for book: BibleBookSummary) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(1...book.chapterCount, id: \.self) { number in
                let isCurrent = book.id == currentBookId && number == currentChapterNumber
                Button {
                    onSelectChapter(book.id, number)
                } label: {
                    Text("\(number)")
                        .font(.system(size: 14, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? theme.backgroundRaised : theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
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
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var orderToggle: some View {
        HStack(spacing: 0) {
            toggleSegment("Traditional", order: .traditional)
            toggleSegment("Alphabetical", order: .alphabetical)
        }
        .padding(4)
        .background(Capsule().fill(theme.backgroundSunken))
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    private func toggleSegment(_ title: String, order: BibleBookOrder) -> some View {
        let isActive = viewModel.order == order
        return Button {
            viewModel.order = order
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
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
        viewModel: BibleBookSheetViewModel(expandedBookId: "1PE"),
        currentBookId: "1PE",
        currentChapterNumber: 2,
        onSelectChapter: { _, _ in },
        onClose: {}
    )
    .superTheme(.make(.light))
}
