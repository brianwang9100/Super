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

/// Drives the book picker sheet: the search query, the list ordering, and
/// which book is expanded to show its chapter grid.
///
/// The view model only filters and groups — it never navigates. Picking a
/// chapter is a callback the sheet hands back to `BibleScreenViewModel`.
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

    private let catalog: BibleBookCatalog

    /// - Parameters:
    ///   - expandedBookId: the book to open with its chapter grid showing —
    ///     the applet passes the reader's current book so the sheet opens
    ///     focused on where the reader already is.
    public init(expandedBookId: String?, catalog: BibleBookCatalog = .standard) {
        self.expandedBookId = expandedBookId
        self.catalog = catalog
    }

    /// The books to display, filtered by `query` and ordered by `order`,
    /// split into titled sections. Empty sections are dropped, so `groups`
    /// is empty exactly when the query matches nothing.
    public var groups: [BibleBookGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

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

    /// `false` only when the current query filters every book away.
    public var hasResults: Bool { !groups.isEmpty }

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
