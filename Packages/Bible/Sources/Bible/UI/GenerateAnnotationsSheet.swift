import Core
import SwiftUI

/// "Choose what to annotate" — a flat book list where each book expands to its
/// chapters. Already-annotated books/chapters carry a "Done" badge. A pinned
/// footer keeps the live estimate beside Generate. Confirming (after a one-tap
/// cost check for remote BYOK models) dismisses the sheet and starts the one job.
struct GenerateAnnotationsSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: BulkAnnotationViewModel
    let requiresCostConfirmation: Bool

    @State private var confirmGenerate = false

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: "Generate", sizing: .expandable, onClose: { dismiss() })

            pickerHeader
            bookList

            footer
        }
        .background(theme.background)
        .sheetPresentation(.expandable)
        .alert("Generate annotations?", isPresented: $confirmGenerate) {
            Button("Generate") { startRun() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This uses your own API key and may incur charges from your model provider. It runs in the background.")
        }
    }

    /// One rendered line in the picker — a book header or one of its chapters.
    /// Pinned header above the scrolling list: the section caption and a
    /// master **Select all** row (toggles every chapter of every book).
    private var pickerHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CHOOSE WHAT TO ANNOTATE")
                .font(typography.mono(10.5, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)

            Button(action: { viewModel.toggleSelectAll() }) {
                HStack(spacing: 12) {
                    BulkCheckBox(
                        checked: viewModel.isAllSelected,
                        partial: viewModel.isAnySelected && !viewModel.isAllSelected
                    )
                    Text("Select all")
                        .font(typography.font(.subheadline, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    if viewModel.selection.selectedChapterCount > 0 {
                        Text("\(viewModel.selection.selectedChapterCount) selected")
                            .font(typography.mono(11))
                            .foregroundStyle(theme.inkMute)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isAllSelected ? "Deselect all" : "Select all")

            Rectangle().fill(theme.borderFaint).frame(height: 0.5)
        }
    }

    /// One rendered line — a book header or one of its chapters. Flattened into
    /// a single list (rather than a `ForEach` of books each nesting a `ForEach`
    /// of chapters) with globally-unique string ids.
    private enum PickerRow: Identifiable {
        case book(BibleBookSummary)
        case chapter(ChapterRef)

        var id: String {
            switch self {
            case .book(let summary): "book:\(summary.id)"
            case .chapter(let ref): "chapter:\(ref.bookID):\(ref.number)"
            }
        }
    }

    private var pickerRows: [PickerRow] {
        var rows: [PickerRow] = []
        for book in viewModel.books {
            rows.append(.book(book))
            if viewModel.isExpanded(book.id) {
                for number in 1...book.chapterCount {
                    rows.append(.chapter(ChapterRef(bookID: book.id, number: number)))
                }
            }
        }
        return rows
    }

    /// A `List` (not `LazyVStack`-in-`ScrollView`): it truly virtualizes, so a
    /// fully-expanded picker (potentially thousands of chapter rows) recycles
    /// cells correctly instead of blanking them under the scroll view's
    /// huge backing layer. Default chrome (separators, insets, background) is
    /// stripped so the rows keep their own custom dividers and surfaces.
    private var bookList: some View {
        List(pickerRows) { row in
            rowView(row)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(theme.background)
    }

    @ViewBuilder
    private func rowView(_ row: PickerRow) -> some View {
        switch row {
        case .book(let book):
            let state = viewModel.selection.bookSelectionState(book.id, chapterCount: book.chapterCount)
            BulkBookSelectionRow(
                name: book.name,
                chapterCount: book.chapterCount,
                checked: state == .full,
                partial: state == .partial,
                done: viewModel.bookDone(book.id),
                expanded: viewModel.isExpanded(book.id),
                onToggleSelect: { viewModel.toggleBook(book) },
                onToggleExpand: { viewModel.toggleExpand(book.id) }
            )
        case .chapter(let ref):
            BulkChapterSelectionRow(
                number: ref.number,
                checked: viewModel.selection.isChapterSelected(ref),
                done: viewModel.chapterDone(ref),
                onToggleSelect: { viewModel.toggleChapter(ref) }
            )
        }
    }

    private var footer: some View {
        let estimate = viewModel.estimate
        return VStack(spacing: 11) {
            Toggle(isOn: $viewModel.overwriteExisting) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overwrite existing annotations")
                        .font(typography.font(.subheadline, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Text("Off keeps chapters you've already annotated")
                        .font(typography.mono(10.5))
                        .foregroundStyle(theme.inkFaint)
                }
            }
            .tint(theme.accent)
            .accessibilityHint("When off, already-annotated chapters are skipped instead of regenerated")

            Toggle(isOn: $viewModel.annotateNotableVerses) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also annotate notable verses")
                        .font(typography.font(.subheadline, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Text("Up to 5 key passages per chapter — uses more API calls")
                        .font(typography.mono(10.5))
                        .foregroundStyle(theme.inkFaint)
                }
            }
            .tint(theme.accent)
            .accessibilityHint("When on, each chapter also annotates its most notable verse ranges")

            HStack(spacing: 8) {
                Image(systemName: "clock").font(typography.font(size: 13))
                Text("\(estimate.books) \(estimate.books == 1 ? "book" : "books") · ~\(estimate.annotations) annotations · est. \(estimate.minutes) min")
                    .font(typography.mono(11.5))
            }
            .foregroundStyle(theme.inkFaint)
            .opacity(viewModel.selection.isEmpty ? 0 : 1)

            BulkPrimaryButton(title: "Generate", systemImage: "sparkles") {
                if requiresCostConfirmation { confirmGenerate = true } else { startRun() }
            }
            .opacity(viewModel.selection.isEmpty ? 0.5 : 1)
            .disabled(viewModel.selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(theme.background)
        .overlay(alignment: .top) { Rectangle().fill(theme.borderFaint).frame(height: 0.5) }
    }

    private func startRun() {
        viewModel.generate()
        dismiss()
    }
}
