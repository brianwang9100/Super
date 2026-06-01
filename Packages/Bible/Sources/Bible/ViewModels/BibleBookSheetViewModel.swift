import Foundation
import Observation

/// One titled section of the book picker. `title` is `nil` for the single
/// flat list shown when searching or in alphabetical order; otherwise it is
/// `"Old Testament"` / `"New Testament"`.
public struct BibleBookGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let books: [BibleBookSummary]

    public init(id: String, title: String?, books: [BibleBookSummary]) {
        self.id = id
        self.title = title
        self.books = books
    }
}

/// Where the picker should anchor its scroll position when it first appears.
///
/// `.bookRow` keeps the current book's name row at the top of the viewport so
/// the chapter grid expands fully into view below it — the common case.
/// `.chapterCell` anchors the highlighted chapter cell itself, used when the
/// book has too many chapters to fit the grid into the visible area below
/// the name row (e.g. Psalms 119), where anchoring on the book name would
/// leave the current chapter off-screen below the fold.
public enum BibleBookSheetScrollAnchor: Hashable, Sendable {
    case bookRow(bookId: String)
    case chapterCell(bookId: String, chapterNumber: Int)
}

/// Drives the book picker sheet: the search query, the list ordering, which
/// book is expanded to show its chapter grid, and where the scroll position
/// should anchor when the sheet first appears.
///
/// The view model only filters, groups, and reports its initial scroll
/// target — it never navigates. Picking a chapter is a callback the sheet
/// hands back to `BibleScreenViewModel`.
@MainActor
@Observable
public final class BibleBookSheetViewModel {
    /// Case-insensitive substring filter over book names; empty shows all.
    public var query: String = ""
    /// Whether the list is grouped by testament or flattened A–Z.
    public var order: BibleBookOrder = .traditional
    /// The book whose chapter grid is open, or `nil` if none is expanded.
    ///
    /// Independent of `query` — a filtered-out book stays "expanded" and
    /// reappears as such once the search clears, so the reader returns to
    /// the book they were focused on.
    public private(set) var expandedBookId: String?

    /// The reader's current position when the sheet was opened, or `nil` if
    /// no position was supplied. Drives `initialScrollAnchor`; never mutated.
    public let currentPosition: BiblePosition?

    private let catalog: BibleBookCatalog

    /// Columns in the chapter grid; the view lays cells out at this width
    /// and the threshold below divides chapter numbers by it to compute
    /// the grid-row index. Kept here so the math and the layout can't
    /// drift out of sync.
    static let chapterGridColumns = 6

    /// Grid-row threshold above which the chapter cell itself is anchored
    /// instead of the book name row. The picker's content area below the
    /// name row fits roughly 8 grid rows at default Dynamic Type, so once
    /// the current chapter sits past row index 8 (chapter 49 and on)
    /// anchoring on the name row would push the current chapter cell off
    /// the bottom edge. The threshold is calibrated for default Dynamic
    /// Type; readers at much larger type sizes may still see the chapter
    /// scrolled below the fold for medium-late chapters — addressing that
    /// would mean threading the picker's measured content height into the
    /// view model, which is out of scope for v1.
    private static let chapterGridRowAnchorThreshold = 8

    /// - Parameters:
    ///   - currentPosition: the reader's current book + chapter; when
    ///     non-nil, that book opens with its chapter grid showing and the
    ///     sheet scrolls so the current chapter is on screen. `nil` opens
    ///     the picker with every book collapsed and scrolled to the top
    ///     of the canon — used by previews and call sites without a
    ///     position to thread in.
    public init(currentPosition: BiblePosition?, catalog: BibleBookCatalog = .standard) {
        self.currentPosition = currentPosition
        self.expandedBookId = currentPosition?.bookId
        self.catalog = catalog
    }

    /// The parsed search query — the book-name filter plus an optional
    /// chapter / verse deep-link target. Recomputed from `query` on demand;
    /// drives `groups`, `deepLinkResult`, and `autoExpandedBookId`.
    private var parsed: BibleSearchQuery {
        BibleSearchQueryParser.parse(query, in: catalog)
    }

    /// A resolved chapter / verse range when the query named one (e.g.
    /// `"1 Peter 2:5-6"`), else `nil`. Non-nil makes the picker show a single
    /// deep-link row in place of the book list.
    public var deepLinkResult: BibleSearchResult? { parsed.resolved }

    /// The single book the picker should auto-expand: set when the query is a
    /// book-only search that filters the list down to exactly one book, so its
    /// chapter grid opens without a tap. `nil` while a deep-link is resolved
    /// (the row replaces the list) or whenever zero or many books match.
    public var autoExpandedBookId: String? {
        guard deepLinkResult == nil else { return nil }
        let books = groups.flatMap(\.books)
        return books.count == 1 ? books.first?.id : nil
    }

    /// Whether `bookId`'s chapter grid should be shown — either the user's
    /// manually expanded book or the lone search match the picker auto-expands.
    public func isBookExpanded(_ bookId: String) -> Bool {
        bookId == expandedBookId || bookId == autoExpandedBookId
    }

    /// The books to display, filtered by the query's book-name part and
    /// ordered by `order`, split into titled sections. Empty sections are
    /// dropped, so `groups` is empty exactly when the book filter matches
    /// nothing. When the query resolves to a chapter / verse the picker shows
    /// `deepLinkResult` instead, so `groups` is not consulted then.
    public var groups: [BibleBookGroup] {
        let trimmed = parsed.bookNameQuery.trimmingCharacters(in: .whitespaces)

        var books = catalog.books
        if order == .alphabetical {
            books.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if !trimmed.isEmpty {
            books = books.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }

        // A flat list while searching or sorting A–Z; the testament split
        // only makes sense for the full canon in traditional order.
        if order == .alphabetical || !trimmed.isEmpty {
            return books.isEmpty ? [] : [BibleBookGroup(id: "all", title: nil, books: books)]
        }
        return [
            BibleBookGroup(
                id: "ot",
                title: "Old Testament",
                books: books.filter { $0.testament == .oldTestament }
            ),
            BibleBookGroup(
                id: "nt",
                title: "New Testament",
                books: books.filter { $0.testament == .newTestament }
            ),
        ].filter { !$0.books.isEmpty }
    }

    /// `false` only when the query neither resolves to a deep-link nor leaves
    /// any book in the filtered list.
    public var hasResults: Bool { deepLinkResult != nil || !groups.isEmpty }

    /// Where the picker should anchor on first appear; `nil` when no
    /// `currentPosition` was supplied (the sheet stays at the top).
    public var initialScrollAnchor: BibleBookSheetScrollAnchor? {
        guard let position = currentPosition else { return nil }
        let rowIndex = (position.chapterNumber - 1) / Self.chapterGridColumns
        if rowIndex >= Self.chapterGridRowAnchorThreshold {
            return .chapterCell(bookId: position.bookId, chapterNumber: position.chapterNumber)
        }
        return .bookRow(bookId: position.bookId)
    }

    /// Open the given book's chapter grid, or close it if it is already the
    /// expanded one — only one book is ever expanded at a time.
    public func toggleExpansion(bookId: String) {
        expandedBookId = (expandedBookId == bookId) ? nil : bookId
    }

    /// Reset the search field to empty, restoring the full book list.
    public func clearQuery() {
        query = ""
    }
}
